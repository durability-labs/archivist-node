## Copyright (c) 2025 Archivist Authors
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import pkg/chronos
import pkg/kvstore/kvstore
import pkg/kvstore/query
import pkg/libp2p/cid
import pkg/questionable
import pkg/questionable/results

import ./coders
import ./keys
import ./types
import ../stores/blockstore
import ../blockexchange/engine
import ../blocktype
import ../clock
import ../logutils
import ../merkletree
import ../utils/safeasynciter

export types

logScope:
  topics = "archivist datasetmanager"

func new*(
    T: type DatasetManager,
    repoStore: BlockStore,
    metaStore: KVStore,
    engine: BlockExcEngine,
    clock: Clock,
): DatasetManager =
  DatasetManager(
    repoStore: repoStore,
    metaStore: metaStore,
    engine: engine,
    clock: clock,
    overlays: initTable[Cid, OverlayState](),
  )

###########################################################
# Dataset State Management
###########################################################

proc getOverlayMetadata*(
    self: DatasetManager, manifestCid: Cid
): Future[?!OverlayMetadata] {.async: (raises: [CancelledError]).} =
  logScope:
    manifestCid = manifestCid

  # Check in-memory cache first
  if self.overlays.hasKey(manifestCid):
    trace "Overlay metadata found in cache"
    return success(self.overlays.getOrDefault(manifestCid).metadata)

  # Load from kvstore
  without key =? datasetOverlayKey(manifestCid), err:
    return failure(err)

  without record =? await self.metaStore.get(key), err:
    trace "Overlay metadata not found", err = err.msg
    return failure(err)

  without meta =? OverlayMetadata.decode(record.val), err:
    return failure(err)

  trace "Overlay metadata loaded from store"
  success(meta)

proc setOverlayMetadata*(
    self: DatasetManager, manifestCid: Cid, meta: OverlayMetadata
): Future[?!void] {.async: (raises: [CancelledError]).} =
  logScope:
    manifestCid = manifestCid
    status = meta.status

  without key =? datasetOverlayKey(manifestCid), err:
    return failure(err)

  # Get existing record to obtain its token (for CAS), or use 0 for new record
  var token: uint64 = 0
  if existingRecord =? await self.metaStore.get(key):
    token = existingRecord.token

  let record = RawRecord.init(key, meta.encode(), token)
  ?await self.metaStore.put(record)

  # Update in-memory cache - always overwrite with new state
  self.overlays[manifestCid] = OverlayState(metadata: meta, presentBlocks: 0)

  trace "Overlay metadata stored"
  success()

proc deleteOverlayMetadata*(
    self: DatasetManager, manifestCid: Cid
): Future[?!void] {.async: (raises: [CancelledError]).} =
  logScope:
    manifestCid = manifestCid

  without key =? datasetOverlayKey(manifestCid), err:
    return failure(err)

  # Get existing record to obtain its token (for CAS)
  without existingRecord =? await self.metaStore.get(key), err:
    # If not found, that's fine - nothing to delete
    trace "Overlay metadata not found for deletion"
    return success()

  ?await self.metaStore.delete(KeyRecord.init(key, existingRecord.token))

  # Remove from cache
  self.overlays.del(manifestCid)

  trace "Overlay metadata deleted"
  success()

proc listDatasets*(
    self: DatasetManager
): Future[?!seq[Cid]] {.async: (raises: [CancelledError]).} =
  without queryKey =? datasetsQueryKey(), err:
    return failure(err)

  without iter =? await self.metaStore.query(Query.init(queryKey)), err:
    return failure(err)

  var datasets = newSeq[Cid]()
  while not iter.finished:
    without recordOpt =? await iter.next(), err:
      warn "Error iterating datasets", err = err.msg
      continue
    without record =? recordOpt:
      continue # End of iteration
    without cid =? Cid.init(record.key.value).mapFailure, err:
      warn "Failed to parse CID from key", key = record.key, err = err.msg
      continue
    datasets.add(cid)

  iter.dispose()
  success(datasets)

proc listDatasetsInState*(
    self: DatasetManager, status: DatasetStatus
): Future[?!seq[Cid]] {.async: (raises: [CancelledError]).} =
  without queryKey =? datasetsQueryKey(), err:
    return failure(err)

  without iter =? await self.metaStore.query(Query.init(queryKey)), err:
    return failure(err)

  var datasets = newSeq[Cid]()
  while not iter.finished:
    without recordOpt =? await iter.next(), err:
      warn "Error iterating datasets", err = err.msg
      continue
    without record =? recordOpt:
      continue # End of iteration
    without meta =? OverlayMetadata.decode(record.val), err:
      warn "Failed to decode metadata", err = err.msg
      continue
    if meta.status != status:
      continue
    without cid =? Cid.init(record.key.value).mapFailure, err:
      warn "Failed to parse CID from key", key = record.key, err = err.msg
      continue
    datasets.add(cid)

  iter.dispose()
  success(datasets)

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
  await self.repoStore.close()
