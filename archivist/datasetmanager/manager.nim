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

import std/sequtils
import std/tables

import pkg/chronos
import pkg/libp2p/cid
import pkg/questionable
import pkg/questionable/results

import pkg/libp2p/[multicodec, multihash]
import pkg/libp2p/stream/lpstream

import ./store
import ./types
import ../stores/blockstore
import ../stores/repostore
import ../blockexchange/engine
import ../blocktype
import ../chunker
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
    downloads*: Table[Cid, DownloadHandle] ## Active downloads keyed by treeCid

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
# Dataset State Management - Internal (treeCid-based)
###########################################################

proc getOverlayMetadata(
    self: DatasetManager, treeCid: Cid
): Future[?!OverlayMetadata] {.async: (raw: true, raises: [CancelledError]).} =
  self.datasetStore.getOverlayMetadata(treeCid)

proc setOverlayMetadata(
    self: DatasetManager, treeCid: Cid, meta: OverlayMetadata
): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
  self.datasetStore.setOverlayMetadata(treeCid, meta)

proc deleteOverlayMetadata(
    self: DatasetManager, treeCid: Cid
): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
  self.datasetStore.deleteOverlayMetadata(treeCid)

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
    self: DatasetManager, treeCid: Cid, manifest: Manifest
) {.async: (raises: []).} =
  logScope:
    treeCid = treeCid
    blocksCount = manifest.blocksCount

  trace "Starting dataset download"

  let totalBlocks = manifest.blocksCount

  try:
    for index in 0 ..< totalBlocks:
      logScope:
        index = index

      if hasBlk =? await self.repoStore.hasBlock(treeCid, index):
        if hasBlk:
          trace "Block already local, skipping"
          continue

      trace "Requesting block from network"
      if blk =? await self.engine.requestBlock(BlockAddress.init(treeCid, index)):
        if err =? (await self.putBlock(blk)).errorOption:
          warn "Failed to store downloaded block", err = err.msg
      else:
        trace "Failed to retrieve block from network"

    if meta =? await self.getOverlayMetadata(treeCid):
      var updatedMeta = meta
      updatedMeta.status = Completed
      if err =? (await self.setOverlayMetadata(treeCid, updatedMeta)).errorOption:
        warn "Failed to update overlay status to Completed", err = err.msg

    trace "Dataset download completed"
  except CancelledError:
    trace "Dataset download cancelled"

proc downloadDataset*(
    self: DatasetManager, manifestCid: Cid, expiry: SecondsSince1970 = 0
): Future[?!void] {.async: (raises: [CancelledError]).} =
  logScope:
    manifestCid = manifestCid

  trace "Fetching manifest"
  let manifestBlk = ?await self.getBlock(manifestCid)

  without manifest =? Manifest.decode(manifestBlk), err:
    return
      failure(newException(ArchivistError, "Failed to decode manifest: " & err.msg))

  let treeCid = manifest.treeCid

  logScope:
    treeCid = treeCid

  if treeCid in self.downloads:
    trace "Dataset already downloading"
    return failure(newException(ArchivistError, "Dataset already downloading"))

  if meta =? await self.getOverlayMetadata(treeCid):
    if meta.status == Completed:
      trace "Dataset already completed"
      return success()
    if meta.status == Downloading:
      trace "Dataset marked as downloading but no active download, resuming"

  let meta = OverlayMetadata(
    status: Downloading, manifestCid: manifestCid, expiry: expiry, downloadedBlocks: @[]
  )
  ?await self.setOverlayMetadata(treeCid, meta)

  trace "Starting download", totalBlocks = manifest.blocksCount

  let downloadFut = self.downloadInternal(treeCid, manifest)

  self.downloads[treeCid] = downloadFut

  proc cleanup(data: pointer) {.raises: [].} =
    self.downloads.del(treeCid)

  downloadFut.addCallback(cleanup)
  self.trackedFutures.track(downloadFut)

  success()

proc getProgress*(
    self: DatasetManager, manifestCid: Cid
): Future[?!(uint32, uint32)] {.async: (raises: [CancelledError]).} =
  logScope:
    manifestCid = manifestCid

  let manifestBlk = ?await self.getBlock(manifestCid)
  without manifest =? Manifest.decode(manifestBlk), err:
    return
      failure(newException(ArchivistError, "Failed to decode manifest: " & err.msg))

  let treeCid = manifest.treeCid

  without meta =? await self.getOverlayMetadata(treeCid), err:
    return failure(err)

  let totalBlocks = manifest.blocksCount.uint32

  var presentBlocks: uint32 = 0
  for index in 0 ..< totalBlocks.int:
    if hasBlk =? await self.repoStore.hasBlock(treeCid, index):
      if hasBlk:
        presentBlocks.inc

  trace "Progress", presentBlocks = presentBlocks, totalBlocks = totalBlocks
  success((presentBlocks, totalBlocks))

proc cancelDownload*(
    self: DatasetManager, manifestCid: Cid
): Future[?!void] {.async: (raises: [CancelledError]).} =
  logScope:
    manifestCid = manifestCid

  let manifestBlk = ?await self.getBlock(manifestCid)
  without manifest =? Manifest.decode(manifestBlk), err:
    return
      failure(newException(ArchivistError, "Failed to decode manifest: " & err.msg))

  let treeCid = manifest.treeCid

  var downloadFut: DownloadHandle
  self.downloads.withValue(treeCid, fut):
    downloadFut = fut[]
  do:
    trace "No active download to cancel"
    return failure(newException(ArchivistError, "No active download for this dataset"))

  trace "Cancelling download"
  await downloadFut.cancelAndWait()

  success()

proc deleteOverlay*(
    self: DatasetManager, manifestCid: Cid
): Future[?!void] {.async: (raises: [CancelledError]).} =
  logScope:
    manifestCid = manifestCid

  without manifestBlk =? await self.repoStore.getBlock(manifestCid), err:
    trace "Manifest block not found", err = err.msg
    return failure(err)

  without manifest =? Manifest.decode(manifestBlk), err:
    return
      failure(newException(ArchivistError, "Failed to decode manifest: " & err.msg))

  let treeCid = manifest.treeCid

  logScope:
    treeCid = treeCid

  if treeCid in self.downloads:
    trace "Cancelling active download before delete"
    ?await self.cancelDownload(manifestCid)

  if meta =? await self.getOverlayMetadata(treeCid):
    var updatedMeta = meta
    updatedMeta.status = Deleting
    ?await self.setOverlayMetadata(treeCid, updatedMeta)

  trace "Deleting overlay", blocksCount = manifest.blocksCount

  const RefcountBatchSize = 1000

  if self.repoStore of RepoStore:
    let repo = RepoStore(self.repoStore)

    if cidIter =? await repo.getAllLeafCidsIter(treeCid):
      var
        batch: seq[(Cid, int)]
        totalDereferenced = 0
        totalDeleted = 0

      while not cidIter.finished:
        batch.setLen(0)
        while batch.len < RefcountBatchSize and not cidIter.finished:
          if cid =? await cidIter.next():
            batch.add((cid, -1))

        if batch.len > 0:
          totalDereferenced += batch.len
          let zeroRefCids = ?await repo.batchUpdateRefcounts(batch)

          if zeroRefCids.len > 0:
            let deleted = ?await repo.delBlocksBatch(zeroRefCids)
            totalDeleted += deleted.len

      trace "Refcount updates completed",
        dereferenced = totalDereferenced, deleted = totalDeleted

    if leavesDeleted =? await repo.delLeafCidsBatched(treeCid):
      trace "Deleted leaf mappings", count = leavesDeleted

    if nodesDeleted =? await repo.delTreeNodesBatched(treeCid):
      trace "Deleted tree nodes", count = nodesDeleted

  ?await self.deleteOverlayMetadata(treeCid)

  trace "Overlay deleted"
  success()

# Alias for clarity
proc deleteDataset*(
    self: DatasetManager, manifestCid: Cid
): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
  ## Delete a dataset - alias for deleteOverlay
  self.deleteOverlay(manifestCid)

proc storeDataset*(
    self: DatasetManager,
    stream: LPStream,
    filename: ?string = string.none,
    mimetype: ?string = string.none,
    blockSize = DefaultBlockSize,
    expiry: SecondsSince1970 = 0,
): Future[?!Cid] {.async: (raises: [CancelledError]).} =
  logScope:
    blockSize = blockSize

  trace "Storing dataset"

  let
    hcodec = Sha256HashCodec
    dataCodec = BlockCodec
    chunker = LPStreamChunker.new(stream, chunkSize = blockSize)

  var
    blocks: seq[Block]
    cids: seq[Cid]

  const StoreBatchSize = 100

  try:
    while (let chunk = await chunker.getBytes(); chunk.len > 0):
      without mhash =? MultiHash.digest($hcodec, chunk).mapFailure, err:
        return failure(err)

      without cid =? Cid.init(CIDv1, dataCodec, mhash).mapFailure, err:
        return failure(err)

      without blk =? Block.new(cid, chunk, verify = false):
        return failure("Unable to init block from chunk!")

      cids.add(cid)
      blocks.add(blk)

      if blocks.len >= StoreBatchSize:
        ?await self.putBlocks(blocks)
        blocks.setLen(0)

    if blocks.len > 0:
      ?await self.putBlocks(blocks)
      blocks.setLen(0)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return failure(exc.msg)
  finally:
    await stream.close()

  if cids.len == 0:
    return failure("No data to store")

  without tree =? ArchivistTree.init(cids), err:
    return failure(err)

  without treeCid =? tree.rootCid(CIDv1, dataCodec), err:
    return failure(err)

  for index, cid in cids:
    without proof =? tree.getProof(index), err:
      return failure(err)
    ?await self.repoStore.putCidAndProof(treeCid, index, cid, proof)

  let manifest = Manifest.new(
    treeCid = treeCid,
    blockSize = blockSize,
    datasetSize = NBytes(chunker.offset),
    version = CIDv1,
    hcodec = hcodec,
    codec = dataCodec,
    filename = filename,
    mimetype = mimetype,
  )

  without encodedManifest =? manifest.encode(), err:
    trace "Unable to encode manifest"
    return failure(err)

  without manifestBlk =? Block.new(data = encodedManifest, codec = ManifestCodec), err:
    trace "Unable to create block from manifest"
    return failure(err)

  ?await self.putBlock(manifestBlk)

  let manifestCid = manifestBlk.cid

  let meta = OverlayMetadata(
    status: Completed, manifestCid: manifestCid, expiry: expiry, downloadedBlocks: @[]
  )
  ?await self.setOverlayMetadata(treeCid, meta)

  info "Stored dataset",
    manifestCid = manifestCid,
    treeCid = treeCid,
    blocks = cids.len,
    datasetSize = manifest.datasetSize

  success(manifestCid)

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
