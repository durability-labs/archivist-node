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
import std/tables

import pkg/chronos
import pkg/kvstore
import pkg/libp2p/cid
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
import ../../clock

export blocktype, cid, overlays

logScope:
  topics = "archivist repostore"

###########################################################
# BlockStore API
###########################################################

proc getBlocksBitmap*(
    self: RepoStore, treeCid: Cid
): Future[?!BitSeq] {.async: (raises: [CancelledError]).} =
  ## Get the overlay BitSeq for a given tree CID.
  ##
  ## Returns the bitmap of stored block indices. Use for batch
  ## presence checks (e.g., in fetchBatched) to avoid per-block
  ## overlay metadata fetches. Returns empty BitSeq if overlay
  ## doesn't exist.
  ##

  let key = ?overlayKey(treeCid)

  self.overlayCache.withValue(key, cached):
    return success(cached[].blocks)

  without overlayMeta =? await self.metaDs.get(key, OverlayMetadata), err:
    if err of KVStoreKeyNotFound:
      trace "Overlay not found, returning empty", treeCid
      return success(BitSeq.init(0))
    return failure(err)

  # Re-check cache: a concurrent write may have populated it while we awaited
  self.overlayCache.withValue(key, fresher):
    trace "Overlay cache populated during await, using cached", treeCid
    return success(fresher[].blocks)
  self.overlayCache[key] = overlayMeta.val
  trace "Overlay found", treeCid, bitmapLen = overlayMeta.val.blocks.len
  success(overlayMeta.val.blocks)

proc checkBitmap*(
    self: RepoStore, treeCid: Cid, index: Natural
): Future[?!bool] {.async: (raises: [CancelledError]).} =
  ## Check if the overlay BitSeq has the bit set for the given index.
  ##
  ## Returns true if the bit is set or if the overlay doesn't exist
  ## (caller should proceed with normal lookup). Returns false if the
  ## bit is not set (block is definitely absent - caller can fast-reject).
  ##

  let bits = ?await self.getBlocksBitmap(treeCid)
  if index >= bits.len or not bits[index]:
    return success(false)

  success(true)

method getBlocks*(
    self: RepoStore, cids: seq[Cid]
): Future[?!seq[Block]] {.async: (raises: [CancelledError]).} =
  ## Get multiple blocks by CID from the blockstore (no tree context).
  ## Empty CIDs are synthesized directly. Missing blocks are silently omitted.
  ##

  if cids.len == 0:
    return success(newSeq[Block]())

  var
    keyToCid: Table[Key, Cid]
    blocks: seq[Block]

  for cid in cids:
    if cid.isEmpty:
      blocks.add(?cid.emptyBlock)
      continue

    let key = ?makePrefixKey(self.postFixLen, cid)
    keyToCid[key] = cid

  if keyToCid.len > 0:
    var records = ?await self.repoDs.get(toSeq(keyToCid.keys))
    for record in mitems(records):
      let cid = ?catch(keyToCid[record.key])
      blocks.add(?Block.new(cid, move(record.val), verify = true))

  success(blocks)

method getBlocks*(
    self: RepoStore, treeCid: Cid, indices: seq[Natural]
): Future[?!seq[(Natural, Block)]] {.async: (raises: [CancelledError]).} =
  ## Get multiple blocks by tree CID and indices as a batch.
  ## Delegates to getBlocksAndProofs and strips proofs.
  ##

  success (?await self.getBlocksAndProofs(treeCid, indices)).mapIt((it[0], it[1]))

method putCidsAndProofs*(
    self: RepoStore, treeCid: Cid, items: seq[(Natural, Cid, ArchivistProof)]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Put multiple CIDs and proofs as a batch
  ##

  logScope:
    treeCid = treeCid
    totalItems = items.len

  trace "Storing batch Leaf and Block Metadata"

  if items.len == 0:
    return success()

  if err =? (await self.putLeafBlockMeta(treeCid, items)).errorOption:
    trace "Unable to store batch Leaf and Block Metadata", err = err.msg
    return failure(err)

  return success()

method putCellCidsAndProofs*(
    self: RepoStore, treeCid: Cid, items: seq[(Natural, Cid, Cid, ArchivistProof)]
): Future[?!void] {.async: (raises: [CancelledError]), gcsafe.} =
  ## Put multiple cell CIDs and proofs as a batch for slot proof trees.
  ## Each item is (index, cellCid, blkCid, proof).
  ##

  logScope:
    treeCid = treeCid
    totalItems = items.len

  trace "Storing batch Leaf and Block Metadata"

  if items.len == 0:
    return success()

  if err =? (await self.putCellLeafBlockMeta(treeCid, items)).errorOption:
    trace "Unable to store batch Leaf and Block Metadata", err = err.msg
    return failure(err)

  return success()

method putBlocks*(
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
    uniqueBlks: HashSet[Cid]

  let blocks = collect(newSeq):
    for (blk, idx, proof) in items.deduplicate():
      if not blk.cid.isEmpty:
        totalSize += blk.data.len
        uniqueBlks.incl(blk.cid)
      (idx, blk.cid, proof, blk.data)

  trace "Putting blocks", actualBlocks = blocks.len, totalSize

  if not self.available(totalSize.NBytes):
    return failure(newException(QuotaNotEnoughError, "Blocks would exceed quota!"))

  # Atomic metadata update
  ?await self.putLeafBlockMeta(treeCid, blocks)

  if onBlock =? self.onBlockStored:
    for cid in uniqueBlks:
      await onBlock(cid)

  return success()

method getCid*(
    self: RepoStore, treeCid: Cid, index: Natural
): Future[?!Cid] {.async: (raises: [CancelledError]).} =
  success (?await self.getLeafMetadata(treeCid, index)).blkCid

proc putBlockInternal(
    self: RepoStore, blk: Block
): Future[?!void] {.async: (raises: [CancelledError]).} =
  logScope:
    cid = blk.cid

  if blk.cid.isEmpty:
    trace "Skipping empty block"
    return success()

  if not self.available(blk.data.len.NBytes):
    return failure(newException(QuotaNotEnoughError, "Block would exceed quota!"))

  if err =? (
    await self.metaDs.put(
      ?blockMetaKey(blk.cid), BlockMetadata(refCount: 0, cid: blk.cid)
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

method putBlock*(
    self: RepoStore, blk: Block, ttl = Duration.none
): Future[?!void] {.
    async: (raises: [CancelledError], raw: true),
    deprecated:
      "Use putBlock(treeCid: Cid, items: seq[(Block, Natural, ArchivistProof)])"
.} =
  putBlockInternal(self, blk)

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
    trace "Some blocks were not deleted, likely due to refCount > 0",
      skipped = skipped.len

  return success()

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

method hasBlocks*(
    self: RepoStore, treeCid: Cid, indices: seq[Natural]
): Future[?!seq[(Natural, bool)]] {.async: (raises: [CancelledError]).} =
  ## Check if multiple blocks exist in the overlay bitmap.
  ##
  ## We use the bitmap exclusively for fast checks. By
  ## definition there is no guarantee that a block we
  ## deemed as present may have been deleted between operations.
  ## The ultimate source of truth is the blocks store itself -
  ## either the block is on disk and it will be returned with
  ## a getBlock* variant, or it isn't and it needs to be recovered
  ## or downloaded. Results include the index for caller matching;
  ## ordering is not guaranteed.
  ##

  if indices.len == 0:
    return success(newSeq[(Natural, bool)]())

  let indices = indices.deduplicate()

  var results: seq[(Natural, bool)]
  for idx in indices:
    results.add((idx, ?await self.checkBitmap(treeCid, idx.Natural)))

  success(results)

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

method delBlocks*(
    self: RepoStore, treeCid: Cid, indices: seq[Natural]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Delete multiple blocks by tree CID and indices as a batch.
  ##
  ## Uses delLeafBlockMetadata which performs atomic delete of leaf
  ## metadata and block refcount updates.
  ##

  if indices.len == 0:
    return success()

  logScope:
    treeCid = treeCid
    count = indices.len

  trace "Batch deleting blocks"

  ?await self.delLeafBlockMetadata(treeCid, indices)
  success()

method getBlocksAndProofs*(
    self: RepoStore, treeCid: Cid, indices: seq[Natural]
): Future[?!seq[(Natural, Block, ArchivistProof)]] {.async: (raises: [CancelledError]).} =
  ## Get multiple blocks and proofs as a batch.
  ##
  ## Fetches overlay bitmap once, filters indices, then batch-fetches
  ## leaf metadata and block data in two round-trips total.
  ## Missing blocks are silently omitted from the result.
  ##

  if indices.len == 0:
    return success(newSeq[(Natural, Block, ArchivistProof)]())

  logScope:
    treeCid = treeCid
    count = indices.len

  trace "Batch getting blocks and proofs"

  # Filter to indices present in bitmap
  var presentIndices: seq[Natural]
  for idx in indices:
    if ?await self.checkBitmap(treeCid, idx.Natural):
      presentIndices.add(idx)

  if presentIndices.len == 0:
    return success(newSeq[(Natural, Block, ArchivistProof)]())

  # Batch-fetch leaf metadata for all present indices
  var leafKeys: seq[Key]
  for idx in presentIndices:
    leafKeys.add(?blockLeafKey(treeCid, idx))

  let leafRecords = ?await self.metaDs.get(leafKeys, LeafMetadata)

  trace "Leaf metadata fetched",
    treeCid, leafKeysLen = leafKeys.len, leafRecordsLen = leafRecords.len

  # Collect block data keys from leaf records.
  # leafRecords may be a subset of leafKeys (missing silently skipped).
  # Empty-CID leaves (erasure padding) are synthesized directly without
  # repoDs lookup - they are never stored but callers expect them back.
  var
    keyToCidProof: Table[Key, (Natural, Cid, ArchivistProof)]
    results: seq[(Natural, Block, ArchivistProof)]
  for record in leafRecords:
    let blkCid = record.val.blkCid

    if blkCid.isEmpty:
      let index = ?catch(parseInt(record.key.value))
      results.add((index.Natural, ?blkCid.emptyBlock, record.val.proof))
      continue

    let
      index = ?catch(parseInt(record.key.value))
      proof = record.val.proof
      key = ?makePrefixKey(self.postFixLen, blkCid)
    keyToCidProof[key] = (index.Natural, blkCid, proof)

  if keyToCidProof.len > 0:
    # Batch-fetch block data from FS.
    var blkRecords = ?await self.repoDs.get(toSeq(keyToCidProof.keys))

    for record in mitems(blkRecords):
      let (idx, cid, proof) = ?catch(keyToCidProof[record.key])
      results.add((idx, ?Block.new(cid, move(record.val), verify = false), proof))

  trace "Batch got blocks and proofs", found = results.len
  success(results)

method getCidsAndProofs*(
    self: RepoStore, treeCid: Cid, indices: seq[Natural]
): Future[?!seq[(Cid, ArchivistProof)]] {.async: (raises: [CancelledError]).} =
  ## Get multiple CIDs and proofs as a batch.
  ##
  ## Fetches overlay bitmap once, filters indices, then batch-fetches
  ## leaf metadata. No block data fetch needed - only metadata.
  ## Missing entries are silently omitted from the result.
  ##

  if indices.len == 0:
    return success(newSeq[(Cid, ArchivistProof)]())

  logScope:
    treeCid = treeCid
    count = indices.len

  trace "Batch getting CIDs and proofs"

  # Filter to indices present in bitmap
  var presentIndices: seq[Natural]
  for idx in indices:
    if ?await self.checkBitmap(treeCid, idx.Natural):
      presentIndices.add(idx)

  if presentIndices.len == 0:
    return success(newSeq[(Cid, ArchivistProof)]())

  # Batch-fetch leaf metadata for all present indices
  var leafKeys: seq[Key]
  for idx in presentIndices:
    leafKeys.add(?blockLeafKey(treeCid, idx))

  let leafRecords = ?await self.metaDs.get(leafKeys, LeafMetadata)

  trace "Leaf metadata fetched",
    treeCid, leafKeysLen = leafKeys.len, leafRecordsLen = leafRecords.len

  # Extract CID and proof from each leaf record
  var results: seq[(Cid, ArchivistProof)]
  for record in leafRecords:
    results.add((record.val.blkCid, record.val.proof))

  trace "Batch got CIDs and proofs", found = results.len
  success(results)

method putBlocks*(
    self: RepoStore, treeCid: Cid, blocks: seq[(Natural, Block)]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Put multiple blocks without proofs (for non-leaf blocks)
  ##
  for (index, blk) in blocks:
    ?await self.putBlock(treeCid, blk, index, nil)
  success()

method close*(self: RepoStore): Future[void] {.async: (raises: []).} =
  ## Close the blockstore, cleaning up resources managed by it.
  ## For some implementations this may be a no-op
  ##

  trace "Closing repostore"

  if not self.metaDs.isNil:
    if err =? (await noCancel self.metaDs.close()).errorOption:
      error "Failed to close metadata store!", err = err.msg

  if not self.repoDs.isNil:
    if err =? (await noCancel self.repoDs.close()).errorOption:
      error "Failed to close repods store!", err = err.msg

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

method storeManifest*(
    self: RepoStore, manifest: Manifest
): Future[?!Block] {.async: (raises: [CancelledError]), gcsafe.} =
  ## Store a manifest block with an overlay for the manifest's treeCid.
  ##

  await self.storeManifestBlock(@[manifest.treeCid], manifest)

proc storeVerifiableManifest*(
    self: RepoStore, manifest: Manifest, slotIdx = Natural.none, expiry = ZeroSeconds
): Future[?!Block] {.async: (raises: [CancelledError]), gcsafe.} =
  ## Store a verifiable manifest with overlays for slot roots.
  ## If slotIdx is provided, only that slot's overlay is created.
  ## Otherwise, overlays for all slot roots are created.
  ##

  if not manifest.verifiable:
    return failure(
      newException(
        ArchivistError, "storeVerifiableManifest requires a verifiable manifest"
      )
    )

  let rootCids =
    if idx =? slotIdx:
      @[manifest.slotRoots[idx]]
    else:
      manifest.slotRoots

  await self.storeManifestBlock(rootCids, manifest, expiry)

method fetchManifest*(
    self: RepoStore, cid: Cid
): Future[?!Manifest] {.async: (raises: [CancelledError]), gcsafe.} =
  ## Fetch and decode a manifest from the blockstore.
  ## Retrieves the block by CID and decodes it as a Manifest.
  ##

  without blk =? await self.getBlock(cid), err:
    return failure(err)

  Manifest.decode(blk.data)

proc start*(
    self: RepoStore
): Future[void] {.async: (raises: [CancelledError, ArchivistError]).} =
  ## Start repo
  ##

  if self.started:
    trace "Repo already started"
    return

  trace "Starting repo"

  if error =? (await self.initializeCounters()).errorOption:
    trace "Initializing counters failed", error = error.msg
    let message = "unable to start repo store: " & error.msg
    raise newException(ArchivistError, message)
  trace "Counters initialized",
    quotaUsage = self.quotaUsage, totalBlocks = self.totalBlocks

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
