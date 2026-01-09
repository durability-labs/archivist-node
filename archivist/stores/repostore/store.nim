## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2024 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/sequtils
import std/sets
import std/strutils

import pkg/chronos
import pkg/chronos/futures
import pkg/kvstore
import pkg/kvstore/kvstore as rawkvstore
import pkg/libp2p/[cid, multicodec]
import pkg/questionable
import pkg/questionable/results

import ./coders
import ./types
import ./operations
import ../blockstore
import ../keyutils
import ../../blocktype
import ../../logutils
import ../../merkletree
import ../../utils

export blocktype, cid

logScope:
  topics = "archivist repostore"

###########################################################
# BlockStore API
###########################################################

method getBlock*(
    self: RepoStore, cid: Cid
): Future[?!Block] {.async: (raises: [CancelledError]).} =
  ## Get a block from the blockstore
  ##

  logScope:
    cid = cid

  if cid.isEmpty:
    trace "Empty block, ignoring"
    return cid.emptyBlock

  without key =? makeBlockDataKey(cid), err:
    trace "Error getting key from provider", err = err.msg
    return failure(err)

  without record =? await get[seq[byte]](self.blockStore, key), err:
    if not (err of KVStoreKeyNotFound):
      trace "Error getting block from datastore", err = err.msg, key
      return failure(err)

    return failure(newException(BlockNotFoundError, err.msg))

  trace "Got block for cid", cid
  return Block.new(cid, record.val, verify = true)

method getBlockAndProof*(
    self: RepoStore, treeCid: Cid, index: Natural
): Future[?!(Block, ArchivistProof)] {.async: (raises: [CancelledError]).} =
  without leafMd =? await self.getLeafMetadata(treeCid, index), err:
    return failure(err)

  without blk =? await self.getBlock(leafMd.blkCid), err:
    return failure(err)

  success((blk, leafMd.proof))

method getBlock*(
    self: RepoStore, treeCid: Cid, index: Natural
): Future[?!Block] {.async: (raises: [CancelledError]).} =
  without leafMd =? await self.getLeafMetadata(treeCid, index), err:
    return failure(err)

  await self.getBlock(leafMd.blkCid)

method getBlock*(
    self: RepoStore, address: BlockAddress
): Future[?!Block] {.async: (raw: true, raises: [CancelledError]).} =
  ## Get a block from the blockstore
  ##

  if address.leaf:
    self.getBlock(address.treeCid, address.index)
  else:
    self.getBlock(address.cid)

method putCidAndProof*(
    self: RepoStore, treeCid: Cid, index: Natural, blkCid: Cid, proof: ArchivistProof
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Put a block to the blockstore
  ##

  logScope:
    treeCid = treeCid
    index = index
    blkCid = blkCid

  trace "Storing LeafMetadata"

  without res =? await self.putLeafMetadata(treeCid, index, blkCid, proof), err:
    return failure(err)

  if blkCid.mcodec == BlockCodec:
    if res == Stored:
      if err =? (await self.updateBlockMetadata(blkCid, plusRefCount = 1)).errorOption:
        return failure(err)
      trace "Leaf metadata stored, block refCount incremented"
    else:
      trace "Leaf metadata already exists"

  return success()

method getCidAndProof*(
    self: RepoStore, treeCid: Cid, index: Natural
): Future[?!(Cid, ArchivistProof)] {.async: (raises: [CancelledError]).} =
  without leafMd =? await self.getLeafMetadata(treeCid, index), err:
    return failure(err)

  success((leafMd.blkCid, leafMd.proof))

method getCid*(
    self: RepoStore, treeCid: Cid, index: Natural
): Future[?!Cid] {.async: (raises: [CancelledError]).} =
  without leafMd =? await self.getLeafMetadata(treeCid, index), err:
    return failure(err)

  success(leafMd.blkCid)

method putBlock*(
    self: RepoStore, blk: Block
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Put a single block - wraps batch operation
  logScope:
    cid = blk.cid

  let failed = ?await self.putBlocksBatch(@[blk])
  if failed.len > 0:
    return failure("Failed to store block: " & $blk.cid)

  if onBlock =? self.onBlockStored:
    await onBlock(blk.cid)

  trace "Block stored"
  success()

proc delBlockInternal(
    self: RepoStore, cid: Cid
): Future[?!DeleteResultKind] {.async: (raises: [CancelledError]).} =
  logScope:
    cid = cid

  if cid.isEmpty:
    return success(Deleted)

  trace "Attempting to delete a block"

  without res =? await self.tryDeleteBlock(cid), err:
    return failure(err)

  if res.kind == Deleted:
    trace "Block deleted"
    if err =? (await self.updateTotalBlocksCount(minusCount = 1)).errorOption:
      return failure(err)

    if err =? (await self.updateQuotaUsage(minusUsed = res.released)).errorOption:
      return failure(err)

  success(res.kind)

method delBlock*(
    self: RepoStore, cid: Cid
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Delete a block from the blockstore when block refCount is 0
  ##

  logScope:
    cid = cid

  without outcome =? await self.delBlockInternal(cid), err:
    return failure(err)

  case outcome
  of InUse:
    failure("Directly deleting a block that is part of a dataset is not allowed.")
  of NotFound:
    trace "Block not found, ignoring"
    success()
  of Deleted:
    trace "Block already deleted"
    success()

method delBlock*(
    self: RepoStore, treeCid: Cid, index: Natural
): Future[?!void] {.async: (raises: [CancelledError]).} =
  without leafMd =? await self.getLeafMetadata(treeCid, index), err:
    if err of BlockNotFoundError:
      return success()
    else:
      return failure(err)

  if err =? (await self.delLeafMetadata(treeCid, index)).errorOption:
    error "Failed to delete leaf metadata, block will remain on disk.", err = err.msg
    return failure(err)

  if err =?
      (await self.updateBlockMetadata(leafMd.blkCid, minusRefCount = 1)).errorOption:
    if not (err of BlockNotFoundError):
      return failure(err)

  without _ =? await self.delBlockInternal(leafMd.blkCid), err:
    return failure(err)

  success()

method hasBlock*(
    self: RepoStore, cid: Cid
): Future[?!bool] {.async: (raises: [CancelledError]).} =
  ## Check if the block exists in the blockstore
  ##

  logScope:
    cid = cid

  if cid.isEmpty:
    trace "Empty block, ignoring"
    return success true

  without key =? makeBlockDataKey(cid), err:
    trace "Error getting key from provider", err = err.msg
    return failure(err)

  return await self.blockStore.has(key)

method hasBlock*(
    self: RepoStore, treeCid: Cid, index: Natural
): Future[?!bool] {.async: (raises: [CancelledError]).} =
  without leafMd =? await self.getLeafMetadata(treeCid, index), err:
    if err of BlockNotFoundError:
      return success(false)
    else:
      return failure(err)

  await self.hasBlock(leafMd.blkCid)

method listBlocks*(
    self: RepoStore, blockType = BlockType.Manifest
): Future[?!SafeAsyncIter[Cid]] {.async: (raises: [CancelledError]).} =
  ## Get the list of blocks in the RepoStore.
  ## This is an intensive operation
  ##

  let key =
    case blockType
    of BlockType.Manifest: ArchivistManifestKey
    of BlockType.Block: ArchivistBlocksKey
    of BlockType.Both: ArchivistRepoKey

  let q = Query.init(key, value = false)
  # Use raw query method explicitly to avoid ambiguity
  without queryIter =? (await rawkvstore.query(self.blockStore, q)), err:
    trace "Error querying cids in repo", blockType, err = err.msg
    return failure(err)

  proc next(): Future[?!Cid] {.async: (raises: [CancelledError]).} =
    await idleAsync()
    without maybeRecord =? await queryIter.next():
      return Cid.failure("No or invalid Cid")

    if record =? maybeRecord:
      trace "Retrieved record from repo", key = record.key
      # Extract CID from key - the key format is /repo/blocks/{cid} or /repo/manifests/{cid}
      let keyStr = record.key.id
      let parts = keyStr.split('/')
      if parts.len > 0:
        return Cid.init(parts[^1]).mapFailure

    return Cid.failure("No or invalid Cid")

  proc isFinished(): bool =
    queryIter.finished

  return success SafeAsyncIter[Cid].new(next, isFinished)

proc blockRefCount*(self: RepoStore, cid: Cid): Future[?!Natural] {.async.} =
  without key =? makeBlockMetadataKey(cid), err:
    return failure(err)

  without record =? await get[BlockMetadata](self.metaStore, key), err:
    return failure(err)

  return success(record.val.refCount)

method getBlockExpirations*(
    self: RepoStore, maxNumber: int, offset: int
): Future[?!SafeAsyncIter[BlockExpiration]] {.
    async: (raises: [CancelledError]), base, gcsafe, deprecated
.} =
  ## Deprecated: block-level expiry removed, use OverlayMaintainer instead
  proc next(): Future[?!BlockExpiration] {.async: (raises: [CancelledError]).} =
    failure(newException(CatchableError, "No more items"))

  proc isFinished(): bool =
    true

  success SafeAsyncIter[BlockExpiration].new(next, isFinished)

###########################################################
# Batch operations (use batch-centric implementations)
###########################################################

method putBlocks*(
    self: RepoStore, blocks: seq[Block]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Put multiple blocks with atomic metadata commit
  let failed = ?await self.putBlocksBatch(blocks)
  if failed.len > 0:
    return failure("Failed to store " & $failed.len & " blocks")

  # Fire callbacks for successfully stored blocks
  if onBlock =? self.onBlockStored:
    let failedSet = failed.toHashSet
    for blk in blocks:
      if blk.cid notin failedSet:
        await onBlock(blk.cid)

  success()

method getBlocks*(
    self: RepoStore, addresses: seq[BlockAddress]
): Future[?!seq[Block]] {.async: (raises: [CancelledError]).} =
  ## Get multiple blocks - separates leaf and direct addresses
  # Separate leaf addresses (need metadata lookup) from direct CID addresses
  var directCids: seq[Cid]
  var leafAddresses: seq[(int, Cid, Natural)] # (originalIdx, treeCid, index)

  for i, address in addresses:
    if address.leaf:
      leafAddresses.add((i, address.treeCid, address.index))
    else:
      directCids.add(address.cid)

  # Get direct blocks via batch
  var blocks = newSeq[Block](addresses.len)

  if directCids.len > 0:
    let directBlocks = ?await self.getBlocksBatch(directCids)
    var directIdx = 0
    for i, address in addresses:
      if not address.leaf:
        blocks[i] = directBlocks[directIdx]
        directIdx.inc

  # Get leaf blocks (need metadata lookup first)
  for (origIdx, treeCid, index) in leafAddresses:
    blocks[origIdx] = ?await self.getBlock(treeCid, index)

  success(blocks)

method getBlocks*(
    self: RepoStore, treeCid: Cid, indices: seq[Natural]
): Future[?!seq[Block]] {.async: (raises: [CancelledError]).} =
  ## Get multiple blocks by tree + indices
  var blocks = newSeq[Block](indices.len)
  for i, index in indices:
    blocks[i] = ?await self.getBlock(treeCid, index)
  success(blocks)

method delBlocks*(
    self: RepoStore, addresses: seq[BlockAddress]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Delete multiple blocks
  # Handle leaf addresses separately (need refcount decrement)
  for address in addresses:
    if address.leaf:
      ?await self.delBlock(address.treeCid, address.index)
    else:
      # Direct CID deletes can be batched
      discard await self.delBlocksBatch(@[address.cid])
  success()

method delBlocks*(
    self: RepoStore, treeCid: Cid, indices: seq[Natural]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Delete multiple blocks by tree + indices
  for index in indices:
    ?await self.delBlock(treeCid, index)
  success()

method getBlockRange*(
    self: RepoStore, treeCid: Cid, start: Natural, count: Natural
): Future[?!seq[Block]] {.async: (raises: [CancelledError]).} =
  ## Get a range of blocks - uses batch internally
  var indices: seq[Natural]
  for i in start ..< start + count:
    indices.add(i.Natural)
  await self.getBlocks(treeCid, indices)

method getBlockAndProof*(
    self: RepoStore, address: BlockAddress
): Future[?!(Block, ArchivistProof)] {.async: (raises: [CancelledError]).} =
  if not address.leaf:
    return
      failure(newException(BlockNotFoundError, "BlockAddress must be a leaf address"))
  await self.getBlockAndProof(address.treeCid, address.index)

method getBlocksAndProofs*(
    self: RepoStore, addresses: seq[BlockAddress]
): Future[?!seq[(Block, ArchivistProof)]] {.async: (raises: [CancelledError]).} =
  var pairs = newSeq[(Block, ArchivistProof)](addresses.len)
  for i, address in addresses:
    pairs[i] = ?await self.getBlockAndProof(address)
  success(pairs)

method getBlocksAndProofs*(
    self: RepoStore, treeCid: Cid, indices: seq[Natural]
): Future[?!seq[(Block, ArchivistProof)]] {.async: (raises: [CancelledError]).} =
  var pairs = newSeq[(Block, ArchivistProof)](indices.len)
  for i, index in indices:
    pairs[i] = ?await self.getBlockAndProof(treeCid, index)
  success(pairs)

method putCidsAndProofs*(
    self: RepoStore, treeCid: Cid, items: seq[(Natural, Cid, ArchivistProof)]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  for (index, blkCid, proof) in items:
    ?await self.putCidAndProof(treeCid, index, blkCid, proof)
  success()

method getCidsAndProofs*(
    self: RepoStore, treeCid: Cid, indices: seq[Natural]
): Future[?!seq[(Cid, ArchivistProof)]] {.async: (raises: [CancelledError]).} =
  var pairs = newSeq[(Cid, ArchivistProof)](indices.len)
  for i, index in indices:
    pairs[i] = ?await self.getCidAndProof(treeCid, index)
  success(pairs)

method close*(self: RepoStore): Future[void] {.async: (raises: []).} =
  ## Close the blockstore, cleaning up resources managed by it.
  ## For some implementations this may be a no-op
  ##

  trace "Closing repostore"

  if not self.metaStore.isNil:
    try:
      (await noCancel self.metaStore.close()).expect("Should close meta store")
    except CatchableError as err:
      error "Failed to close meta store", err = err.msg

  if not self.blockStore.isNil:
    try:
      (await noCancel self.blockStore.close()).expect("Should close block store")
    except CatchableError as err:
      error "Failed to close block store", err = err.msg

###########################################################
# RepoStore procs
###########################################################

proc reserve*(
    self: RepoStore, bytes: NBytes
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Reserve bytes
  ##

  trace "Reserving bytes", bytes

  await self.updateQuotaUsage(plusReserved = bytes)

proc release*(
    self: RepoStore, bytes: NBytes
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Release bytes
  ##

  trace "Releasing bytes", bytes

  await self.updateQuotaUsage(minusReserved = bytes)

proc start*(
    self: RepoStore
): Future[void] {.async: (raises: [CancelledError, ArchivistError]).} =
  ## Start repo
  ##

  if self.started:
    trace "Repo already started"
    return

  trace "Starting repo"
  if err =? (await self.updateTotalBlocksCount()).errorOption:
    raise newException(ArchivistError, err.msg)

  if err =? (await self.updateQuotaUsage()).errorOption:
    raise newException(ArchivistError, err.msg)

  self.started = true

proc stop*(self: RepoStore): Future[void] {.async: (raises: []).} =
  ## Stop repo
  ##
  if not self.started:
    trace "Repo is not started"
    return

  trace "Stopping repo"
  await self.close()

  self.started = false
