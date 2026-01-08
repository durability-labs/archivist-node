## Copyright (c) 2025 Archivist Authors
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## DatasetManager - Orchestrates dataset lifecycle
##
## Implements BlockStore interface, delegating storage to RepoStore while
## adding network retrieval via BlockExcEngine. Uses DatasetStore for
## persistent dataset metadata.

{.push raises: [].}

import std/tables

import pkg/chronos
import pkg/libp2p/cid
import pkg/questionable
import pkg/questionable/results

import ./store
import ./types
import ../stores/blockstore
import ../blockexchange/engine
import ../blocktype
import ../clock
import ../errors
import ../logutils
import ../manifest
import ../merkletree
import ../utils/safeasynciter
import ../utils/trackedfutures

export store, types

logScope:
  topics = "archivist datasetmanager"

type
  DownloadHandle* = Future[void].Raising([])

  DatasetManager* = ref object of BlockStore
    ## Orchestrates dataset lifecycle - implements BlockStore interface
    ## Delegates block storage to RepoStore, metadata to DatasetStore
    repoStore*: BlockStore
    datasetStore*: DatasetStore
    engine*: BlockExcEngine
    clock*: Clock
    trackedFutures*: TrackedFutures
    downloads*: Table[Cid, DownloadHandle] ## Active downloads by manifest CID

func new*(
    T: type DatasetManager,
    repoStore: BlockStore,
    datasetStore: DatasetStore,
    engine: BlockExcEngine,
    clock: Clock,
): DatasetManager =
  DatasetManager(
    repoStore: repoStore,
    datasetStore: datasetStore,
    engine: engine,
    clock: clock,
    trackedFutures: TrackedFutures(),
    downloads: initTable[Cid, DownloadHandle](),
  )

###########################################################
# Dataset State Management - Delegate to DatasetStore
###########################################################

proc getOverlayMetadata*(
    self: DatasetManager, manifestCid: Cid
): Future[?!OverlayMetadata] {.async: (raw: true, raises: [CancelledError]).} =
  self.datasetStore.getOverlayMetadata(manifestCid)

proc setOverlayMetadata*(
    self: DatasetManager, manifestCid: Cid, meta: OverlayMetadata
): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
  self.datasetStore.setOverlayMetadata(manifestCid, meta)

proc deleteOverlayMetadata*(
    self: DatasetManager, manifestCid: Cid
): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
  self.datasetStore.deleteOverlayMetadata(manifestCid)

proc listDatasets*(
    self: DatasetManager
): Future[?!seq[Cid]] {.async: (raw: true, raises: [CancelledError]).} =
  self.datasetStore.listDatasets()

proc listDatasetsInState*(
    self: DatasetManager, status: DatasetStatus
): Future[?!seq[Cid]] {.async: (raw: true, raises: [CancelledError]).} =
  self.datasetStore.listDatasetsInState(status)

###########################################################
# Dataset Lifecycle Operations
###########################################################

proc downloadInternal(
    self: DatasetManager, manifestCid: Cid, manifest: Manifest
) {.async: (raises: []).} =
  ## Internal download procedure - requests all blocks from network
  ## Runs in the background and updates overlay state

  logScope:
    manifestCid = manifestCid
    treeCid = manifest.treeCid
    blocksCount = manifest.blocksCount

  trace "Starting dataset download"

  let treeCid = manifest.treeCid
  let totalBlocks = manifest.blocksCount

  try:
    # Request each block
    for index in 0 ..< totalBlocks:
      logScope:
        index = index

      # Check if already local
      if hasBlk =? await self.repoStore.hasBlock(treeCid, index):
        if hasBlk:
          trace "Block already local, skipping"
          continue

      # Request from network
      trace "Requesting block from network"
      if blk =? await self.engine.requestBlock(BlockAddress.init(treeCid, index)):
        # Store block (putBlock handles the storage and notifies engine)
        if err =? (await self.putBlock(blk)).errorOption:
          warn "Failed to store downloaded block", err = err.msg
          # Continue to next block - partial downloads are OK
      else:
        trace "Failed to retrieve block from network"
        # Continue to next block - partial downloads are OK

    # Update state to Completed
    if meta =? await self.getOverlayMetadata(manifestCid):
      var updatedMeta = meta
      updatedMeta.status = Completed
      if err =? (await self.setOverlayMetadata(manifestCid, updatedMeta)).errorOption:
        warn "Failed to update overlay status to Completed", err = err.msg

    trace "Dataset download completed"
  except CancelledError:
    trace "Dataset download cancelled"

proc downloadDataset*(
    self: DatasetManager, manifestCid: Cid, expiry: SecondsSince1970 = 0
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Start downloading a dataset
  ##
  ## 1. Check if already downloading (return error if so)
  ## 2. Set state to Downloading
  ## 3. Fetch manifest via getBlock
  ## 4. Extract block list from manifest
  ## 5. Request blocks via engine
  ## 6. Track progress as blocks arrive
  ## 7. On completion: state = Completed

  logScope:
    manifestCid = manifestCid

  # Check if already downloading
  if manifestCid in self.downloads:
    trace "Dataset already downloading"
    return failure(newException(ArchivistError, "Dataset already downloading"))

  # Check if already exists and completed
  if meta =? await self.getOverlayMetadata(manifestCid):
    if meta.status == Completed:
      trace "Dataset already completed"
      return success()
    if meta.status == Downloading:
      trace "Dataset marked as downloading but no active download"
      # Continue - may be resuming after crash

  # Fetch manifest block
  trace "Fetching manifest"
  let manifestBlk = ?await self.getBlock(manifestCid)

  # Decode manifest
  without manifest =? Manifest.decode(manifestBlk), err:
    return
      failure(newException(ArchivistError, "Failed to decode manifest: " & err.msg))

  # Create overlay metadata
  let meta = OverlayMetadata(
    status: Downloading,
    manifestCid: manifestCid,
    totalBlocks: manifest.blocksCount.uint32,
    totalSize: manifest.datasetSize.uint64,
    expiry: expiry,
    kind: DatasetOverlay,
    parentTreeCid: Cid.none,
  )
  ?await self.setOverlayMetadata(manifestCid, meta)

  trace "Starting download", totalBlocks = manifest.blocksCount

  # Create download future and track it
  let downloadFut = self.downloadInternal(manifestCid, manifest)

  # Store handle for cancellation
  self.downloads[manifestCid] = downloadFut

  # Track and cleanup when done
  proc cleanup(data: pointer) {.raises: [].} =
    self.downloads.del(manifestCid)

  downloadFut.addCallback(cleanup)
  self.trackedFutures.track(downloadFut)

  success()

proc getProgress*(
    self: DatasetManager, manifestCid: Cid
): Future[?!(uint32, uint32)] {.async: (raises: [CancelledError]).} =
  ## Get download progress for a dataset
  ## Returns (presentBlocks, totalBlocks)

  logScope:
    manifestCid = manifestCid

  # Get overlay metadata for total blocks
  without meta =? await self.getOverlayMetadata(manifestCid), err:
    return failure(err)

  let totalBlocks = meta.totalBlocks

  # Get manifest to find treeCid
  let manifestBlk = ?await self.getBlock(manifestCid)
  without manifest =? Manifest.decode(manifestBlk), err:
    return
      failure(newException(ArchivistError, "Failed to decode manifest: " & err.msg))

  # Count present blocks
  var presentBlocks: uint32 = 0
  for index in 0 ..< totalBlocks.int:
    if hasBlk =? await self.repoStore.hasBlock(manifest.treeCid, index):
      if hasBlk:
        presentBlocks.inc

  trace "Progress", presentBlocks = presentBlocks, totalBlocks = totalBlocks
  success((presentBlocks, totalBlocks))

proc cancelDownload*(
    self: DatasetManager, manifestCid: Cid
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Cancel an active download

  logScope:
    manifestCid = manifestCid

  # Check if downloading and get the future
  var downloadFut: DownloadHandle
  self.downloads.withValue(manifestCid, fut):
    downloadFut = fut[]
  do:
    trace "No active download to cancel"
    return failure(newException(ArchivistError, "No active download for this manifest"))

  trace "Cancelling download"

  # Cancel the download future
  await downloadFut.cancelAndWait()

  # Update state
  if meta =? await self.getOverlayMetadata(manifestCid):
    var updatedMeta = meta
    updatedMeta.status = Pending # Reset to pending since not complete
    if err =? (await self.setOverlayMetadata(manifestCid, updatedMeta)).errorOption:
      warn "Failed to update overlay status", err = err.msg

  success()

proc deleteOverlay*(
    self: DatasetManager, manifestCid: Cid
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Delete a dataset overlay and its metadata
  ##
  ## Note: This does NOT delete blocks - block deletion with refcount
  ## management will be implemented when RepoStore has refcount support

  logScope:
    manifestCid = manifestCid

  # Check if downloading and cancel first
  if manifestCid in self.downloads:
    trace "Cancelling active download before delete"
    ?await self.cancelDownload(manifestCid)

  # Get metadata to set state to Deleting
  if meta =? await self.getOverlayMetadata(manifestCid):
    var updatedMeta = meta
    updatedMeta.status = Deleting
    ?await self.setOverlayMetadata(manifestCid, updatedMeta)

  # Delete the overlay metadata
  ?await self.deleteOverlayMetadata(manifestCid)

  trace "Overlay deleted"
  success()

# Alias for clarity
proc deleteDataset*(
    self: DatasetManager, manifestCid: Cid
): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
  ## Delete a dataset - alias for deleteOverlay
  self.deleteOverlay(manifestCid)

###########################################################
# BlockStore Interface - Single Block Operations
###########################################################

method putBlock*(
    self: DatasetManager, blk: Block
): Future[?!void] {.async: (raises: [CancelledError]).} =
  logScope:
    cid = blk.cid

  trace "Storing block"

  # Write to underlying store
  ?await self.repoStore.putBlock(blk)

  # Cancel any outstanding download request for this block
  self.engine.completeBlock(BlockAddress.init(blk.cid), blk)

  success()

method getBlock*(
    self: DatasetManager, cid: Cid
): Future[?!Block] {.async: (raises: [CancelledError]).} =
  logScope:
    cid = cid

  without blk =? await self.repoStore.getBlock(cid):
    trace "Block not local, requesting from network"
    return await self.engine.requestBlock(cid)

  trace "Block found locally"
  success(blk)

method getBlock*(
    self: DatasetManager, treeCid: Cid, index: Natural
): Future[?!Block] {.async: (raises: [CancelledError]).} =
  logScope:
    treeCid = treeCid
    index = index

  without blk =? await self.repoStore.getBlock(treeCid, index):
    trace "Block not local, requesting from network"
    return await self.engine.requestBlock(BlockAddress.init(treeCid, index))

  trace "Block found locally"
  success(blk)

method getBlock*(
    self: DatasetManager, address: BlockAddress
): Future[?!Block] {.async: (raises: [CancelledError]).} =
  if address.leaf:
    await self.getBlock(address.treeCid, address.index)
  else:
    await self.getBlock(address.cid)

method hasBlock*(
    self: DatasetManager, cid: Cid
): Future[?!bool] {.async: (raw: true, raises: [CancelledError]).} =
  self.repoStore.hasBlock(cid)

method hasBlock*(
    self: DatasetManager, treeCid: Cid, index: Natural
): Future[?!bool] {.async: (raw: true, raises: [CancelledError]).} =
  self.repoStore.hasBlock(treeCid, index)

method delBlock*(
    self: DatasetManager, cid: Cid
): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
  self.repoStore.delBlock(cid)

method delBlock*(
    self: DatasetManager, treeCid: Cid, index: Natural
): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
  self.repoStore.delBlock(treeCid, index)

method listBlocks*(
    self: DatasetManager, blockType = BlockType.Manifest
): Future[?!SafeAsyncIter[Cid]] {.async: (raw: true, raises: [CancelledError]).} =
  self.repoStore.listBlocks(blockType)

###########################################################
# BlockStore Interface - Batch Operations
###########################################################

method putBlocks*(
    self: DatasetManager, blocks: seq[Block]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  for blk in blocks:
    ?await self.putBlock(blk)
  success()

method getBlocks*(
    self: DatasetManager, addresses: seq[BlockAddress]
): Future[?!seq[Block]] {.async: (raises: [CancelledError]).} =
  var blocks = newSeq[Block](addresses.len)
  for i, address in addresses:
    blocks[i] = ?await self.getBlock(address)
  success(blocks)

method getBlocks*(
    self: DatasetManager, treeCid: Cid, indices: seq[Natural]
): Future[?!seq[Block]] {.async: (raises: [CancelledError]).} =
  var blocks = newSeq[Block](indices.len)
  for i, index in indices:
    blocks[i] = ?await self.getBlock(treeCid, index)
  success(blocks)

method delBlocks*(
    self: DatasetManager, addresses: seq[BlockAddress]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  for address in addresses:
    if address.leaf:
      ?await self.delBlock(address.treeCid, address.index)
    else:
      ?await self.delBlock(address.cid)
  success()

method delBlocks*(
    self: DatasetManager, treeCid: Cid, indices: seq[Natural]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  for index in indices:
    ?await self.delBlock(treeCid, index)
  success()

method getBlockRange*(
    self: DatasetManager, treeCid: Cid, start: Natural, count: Natural
): Future[?!seq[Block]] {.async: (raises: [CancelledError]).} =
  var blocks = newSeq[Block](count)
  for i in 0 ..< count:
    blocks[i] = ?await self.getBlock(treeCid, start + i)
  success(blocks)

###########################################################
# BlockStore Interface - Proof Operations (delegate to RepoStore)
###########################################################

method getBlockAndProof*(
    self: DatasetManager, treeCid: Cid, index: Natural
): Future[?!(Block, ArchivistProof)] {.async: (raw: true, raises: [CancelledError]).} =
  self.repoStore.getBlockAndProof(treeCid, index)

method getBlockAndProof*(
    self: DatasetManager, address: BlockAddress
): Future[?!(Block, ArchivistProof)] {.async: (raw: true, raises: [CancelledError]).} =
  self.repoStore.getBlockAndProof(address)

method putCidAndProof*(
    self: DatasetManager,
    treeCid: Cid,
    index: Natural,
    blkCid: Cid,
    proof: ArchivistProof,
): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
  self.repoStore.putCidAndProof(treeCid, index, blkCid, proof)

method getCidAndProof*(
    self: DatasetManager, treeCid: Cid, index: Natural
): Future[?!(Cid, ArchivistProof)] {.async: (raw: true, raises: [CancelledError]).} =
  self.repoStore.getCidAndProof(treeCid, index)

method getBlocksAndProofs*(
    self: DatasetManager, addresses: seq[BlockAddress]
): Future[?!seq[(Block, ArchivistProof)]] {.
    async: (raw: true, raises: [CancelledError])
.} =
  self.repoStore.getBlocksAndProofs(addresses)

method getBlocksAndProofs*(
    self: DatasetManager, treeCid: Cid, indices: seq[Natural]
): Future[?!seq[(Block, ArchivistProof)]] {.
    async: (raw: true, raises: [CancelledError])
.} =
  self.repoStore.getBlocksAndProofs(treeCid, indices)

method putCidsAndProofs*(
    self: DatasetManager, treeCid: Cid, items: seq[(Natural, Cid, ArchivistProof)]
): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
  self.repoStore.putCidsAndProofs(treeCid, items)

method getCidsAndProofs*(
    self: DatasetManager, treeCid: Cid, indices: seq[Natural]
): Future[?!seq[(Cid, ArchivistProof)]] {.async: (raw: true, raises: [CancelledError]).} =
  self.repoStore.getCidsAndProofs(treeCid, indices)

###########################################################
# BlockStore Interface - Lifecycle
###########################################################

method close*(self: DatasetManager): Future[void] {.async: (raises: []).} =
  trace "Closing DatasetManager"

  # Cancel all tracked futures (including active downloads)
  await self.trackedFutures.cancelTracked()

  # Clear downloads table
  self.downloads.clear()

  await self.repoStore.close()
