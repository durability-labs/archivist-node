## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2024 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/sets

import pkg/chronos
import pkg/kvstore
import pkg/libp2p/[cid, multicodec]
import pkg/questionable
import pkg/questionable/results
import pkg/stew/bitseqs

import ./overlays
import ./types
import ./operations
import ../blockstore
import ../keyutils
import ../../blocktype
import ../../logutils
import ../../merkletree
import ../../utils
import ../../manifest

export blocktype, cid, overlays

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

  let key = ?makePrefixKey(self.postFixLen, cid)

  without record =? await self.repoDs.get(key), err:
    if not (err of KVStoreKeyNotFound):
      trace "Error getting block from datastore", err = err.msg, key
      return failure(err)

    return failure(newException(BlockNotFoundError, err.msg))

  trace "Got block for cid", cid
  return Block.new(cid, record.val, verify = true)

method getBlockAndProof*(
    self: RepoStore, treeCid: Cid, index: Natural
): Future[?!(Block, ArchivistProof)] {.async: (raises: [CancelledError]).} =
  let
    leafMd = ?await self.getLeafMetadata(treeCid, index)
    blk = ?await self.getBlock(leafMd.blkCid)

  success((blk, leafMd.proof))

method getBlock*(
    self: RepoStore, treeCid: Cid, index: Natural
): Future[?!Block] {.async: (raises: [CancelledError]).} =
  let leafMd = ?await self.getLeafMetadata(treeCid, index)
  await self.getBlock(leafMd.blkCid)

method putCidAndProof*(
    self: RepoStore, treeCid: Cid, index: Natural, blkCid: Cid, proof: ArchivistProof
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Put a block to the blockstore
  ##

  logScope:
    treeCid = treeCid
    index = index
    blkCid = blkCid

  trace "Storing Leaf and Block Metadata"

  if err =?
      (await self.putOrUpdateLeafBlockMeta(treeCid, index, blkCid, proof)).errorOption:
    trace "Unable to store Leaf and Block Metadata", err = err.msg
    return failure(err)

  return success()

method getCidAndProof*(
    self: RepoStore, treeCid: Cid, index: Natural
): Future[?!(Cid, ArchivistProof)] {.async: (raises: [CancelledError]).} =
  let leafMd = ?await self.getLeafMetadata(treeCid, index)

  success((leafMd.blkCid, leafMd.proof))

method putLeafsAndBlocks*(
    self: RepoStore, treeCid: Cid, items: seq[(Block, Natural, ArchivistProof)]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Put multiple leafs and blocks as a batch (primary method)
  ##

  logScope:
    treeCid = treeCid
    totalItems = items.len

  trace "Storing Leafs and Blocks"

  if items.len == 0:
    return success()

  var
    totalSize = 0
    uniqeBlks: HashSet[Block] # filter out duplicate leafs for different tree branches

  let blocks = collect(newSeq):
    for (blk, idx, proof) in items.deduplicate():
      if not blk.cid.isEmpty:
        totalSize += blk.data.len
        uniqeBlks.incl(blk)
      (idx, blk.cid, proof, blk.data.len.NBytes)

  trace "Putting blocks", actualBlocks = blocks.len, totalSize

  if not self.available(totalSize.NBytes):
    return failure(newException(QuotaNotEnoughError, "Blocks would exceed quota!"))

  # Atomic metadata update (leaf + block refcount)
  if err =? (await self.putOrUpdateLeafBlockMeta(treeCid, blocks)).errorOption:
    trace "Unable to store Leaf and Block Metadata", err = err.msg
    return failure(err)

  trace "Writting blocks to disc", actualBlocks = blocks.len
  # Write blocks to FS (best effort, idempotent)
  let
    records = uniqeBlks.mapIt(
      RawKVRecord.init(?makePrefixKey(self.postFixLen, it.cid), it.data)
    )
    skipped = (?await self.repoDs.put(records)).toHashSet

  # Count only unique blocks that were successfully written
  var newBlocks, newBytes = 0
  for record in records:
    if record.key notin skipped:
      newBytes += record.val.len
      newBlocks += 1

  if newBlocks > 0:
    ?await self.updateCounters(quotaDelta = newBytes, blocksDelta = newBlocks)

  if onBlock =? self.onBlockStored:
    await allFutures(uniqeBlks.mapIt(onBlock(it.cid)))

  return success()

method putLeafAndBlock*(
    self: RepoStore,
    treeCid: Cid,
    blk: Block,
    index: Natural,
    proof: ArchivistProof = nil,
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Put a leaf and block (wrapper for putLeafsAndBlocks)
  ##

  await self.putLeafsAndBlocks(treeCid, @[(blk, index, proof)])

method getCid*(
    self: RepoStore, treeCid: Cid, index: Natural
): Future[?!Cid] {.async: (raises: [CancelledError]).} =
  success (?await self.getLeafMetadata(treeCid, index)).blkCid

method putBlock*(
    self: RepoStore, blk: Block, ttl = Duration.none
): Future[?!void] {.
    async: (raises: [CancelledError], deprecated: "Use putLeafAndBlock")
.} =
  ## Put a block to the blockstore
  ##
  ## NOTE: historicaly, this method never incremented the
  ## refCount, because there might have not exisisted a
  ## dataset (treeCid) to associate the block, so the block
  ## metadata is inserted with refCount 0. For now, we'll do
  ## the same - if the block metadata already exists, we wont
  ## update it, which explains why we do not return when we get
  ## a conflict, but instead attempt to also put the block, in
  ## case for some reason it was missing from the FS. In any case
  ## this behavior should change, once we integrated overlays,
  ## we'll also implement temp overlays for in-progress uploads,
  ## which will allow us to homogenize the behavior and perform
  ## all the block related operations here, instead of spreading them
  ## across several methods.
  ##

  logScope:
    cid = blk.cid

  if blk.cid.isEmpty:
    trace "Skipping empty block"
    return success()

  if not self.available(blk.data.len.NBytes):
    return failure(newException(QuotaNotEnoughError, "Block would exceed quota!"))

  if err =? (
    await self.metaDs.put(
      ?blockMetaKey(blk.cid),
      BlockMetadata(refCount: 0, cid: blk.cid, size: blk.data.len.NBytes),
    )
  ).errorOption:
    if err of KVConflictError:
      trace "Block metadata already exists", err = err.msg
      # don't return here, allow writing the block on disk
    else:
      trace "Error writing block metadata", err = err.msg
      return failure(err)

  let blkKey = ?makePrefixKey(self.postFixLen, blk.cid)

  # we never update blocks on fs, we only insert
  if err =? (await self.repoDs.put(RawKVRecord.init(blkKey, blk.data))).errorOption:
    if err of KVConflictError:
      trace "Block already in store", err = err.msg
      return success()
    else:
      trace "Error writing block on disk", err = err.msg
      return failure(err)

  ?await self.updateCounters(quotaDelta = blk.data.len, blocksDelta = 1)
  if onBlock =? self.onBlockStored:
    await onBlock(blk.cid)

  return success()

proc blockRefCount*(
    self: RepoStore, cid: Cid
): Future[?!Natural] {.async: (raises: [CancelledError]).} =
  ## Returns the reference count for a block. If the count is zero;
  ## this means the block is eligible for garbage collection.
  ##

  without blockMeta =? (await self.metaDs.get(?blockMetaKey(cid), BlockMetadata)), err:
    trace "Unable to retrieve block metadata", err = err.msg
    return failure(err)

  success blockMeta.val.refCount

method delBlock*(
    self: RepoStore, cid: Cid
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Delete a block from the blockstore when block refCount is 0 or block is expired
  ##

  logScope:
    cid = cid

  if cid.isEmpty:
    trace "Skipping empty Cid"
    return success()

  without refCount =? (await self.blockRefCount(cid)), err:
    if err of KVStoreKeyNotFound:
      return failure(newException(BlockNotFoundError, err.msg))
    return failure(err)

  if refCount > 0.Natural:
    return
      failure("Directly deleting a block that is part of a dataset is not allowed.")

  let skipped = ?await self.tryDeleteBlocks(cid)
  if skipped.len > 0:
    trace "Some blocks were not deleted, likely due to refcCount > 0",
      skipped = skipped.len

  return success()

method delBlock*(
    self: RepoStore, treeCid: Cid, index: Natural
): Future[?!void] {.async: (raises: [CancelledError]).} =
  await self.delLeafBlockMetadata(treeCid, index)

method hasBlock*(
    self: RepoStore, cid: Cid
): Future[?!bool] {.async: (raises: [CancelledError]).} =
  ## Check if the block exists in the blockstore
  ##

  logScope:
    cid = cid

  if cid.isEmpty:
    trace "Skipping empty block"
    return success true

  without key =? makePrefixKey(self.postFixLen, cid), err:
    trace "Error getting key from provider", err = err.msg
    return failure(err)

  return await self.repoDs.has(key)

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

  let query = Query.init(key, value = false)
  without queryIter =? (await self.repoDs.query(query)), err:
    trace "Error querying cids in repo", blockType, err = err.msg
    return failure(err)

  proc next(): Future[?!Cid] {.async: (raises: [CancelledError]).} =
    await idleAsync()
    if maybeRecord =? (await queryIter.next()):
      if record =? maybeRecord:
        trace "Retrieved record from repo", key = record.key
        return Cid.init(record.key.value).mapFailure
    return Cid.failure("No or invalid Cid")

  proc isFinished(): bool =
    queryIter.finished

  proc onDispose(): Future[?!void] {.async: (raises: []).} =
    # kvquery.dispose returns Future[?!void] - await and propagate errors
    return await dispose(queryIter)

  proc isDisposed(): bool =
    queryIter.disposed

  return success SafeAsyncIter[Cid].new(next, isFinished, onDispose, isDisposed)

method close*(self: RepoStore): Future[void] {.async: (raises: []).} =
  ## Close the blockstore, cleaning up resources managed by it.
  ## For some implementations this may be a no-op
  ##

  trace "Closing repostore"

  if not self.metaDs.isNil:
    try:
      (await noCancel self.metaDs.close()).expect("Should meta datastore")
    except CatchableError as err:
      error "Failed to close meta datastore", err = err.msg

  if not self.repoDs.isNil:
    (await noCancel self.repoDs.close()).expect("Should repo datastore")

###########################################################
# RepoStore procs
###########################################################

proc reserve*(
    self: RepoStore, bytes: NBytes
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Reserve bytes
  ##

  trace "Reserving bytes", bytes

  if not self.available(bytes):
    return failure(newException(QuotaNotEnoughError, "Not enough bytes to reserve!"))

  await self.updateCounters(reservedDelta = bytes.int)

proc release*(
    self: RepoStore, bytes: NBytes
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Release bytes
  ##

  trace "Releasing bytes", bytes
  if bytes > self.quotaReservedBytes:
    return failure(newException(QuotaNotEnoughError, "Not enough bytes to release!"))

  await self.updateCounters(reservedDelta = -(bytes.int))

proc storeManifest*(
    self: RepoStore, manifest: Manifest
): Future[?!Block] {.async: (raises: [CancelledError]).} =
  let
    encodedVerifiable = ?manifest.encode()
    blk = ?Block.new(data = encodedVerifiable, codec = ManifestCodec)

  ?await self.putBlock(blk)
  trace "Stored manifest block", cid = blk.cid
  success blk

proc start*(
    self: RepoStore
): Future[void] {.async: (raises: [CancelledError, ArchivistError]).} =
  ## Start repo
  ##

  if self.started:
    trace "Repo already started"
    return

  trace "Starting repo"
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
