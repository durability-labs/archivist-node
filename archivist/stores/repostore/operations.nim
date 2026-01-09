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
import std/tables

import pkg/chronos
import pkg/chronos/futures
import pkg/kvstore
import pkg/kvstore/kvstore as rawkvstore
import pkg/libp2p/cid
import pkg/metrics
import pkg/questionable
import pkg/questionable/results

import ./coders
import ./types
import ../blockstore
import ../keyutils
import ../../blocktype
import ../../logutils
import ../../merkletree

logScope:
  topics = "archivist repostore"

declareGauge(archivist_repostore_blocks, "archivist repostore blocks")
declareGauge(archivist_repostore_bytes_used, "archivist repostore bytes used")
declareGauge(archivist_repostore_bytes_reserved, "archivist repostore bytes reserved")

proc putLeafMetadata*(
    self: RepoStore, treeCid: Cid, index: Natural, blkCid: Cid, proof: ArchivistProof
): Future[?!StoreResultKind] {.async: (raises: [CancelledError]).} =
  without key =? createBlockCidAndProofMetadataKey(treeCid, index), err:
    return failure(err)

  # Check if already exists
  if record =? await get[LeafMetadata](self.metaStore, key):
    return success(AlreadyInStore)

  # Create new leaf metadata
  let md = LeafMetadata(blkCid: blkCid, proof: proof)
  ?await self.metaStore.put(key, md)
  success(Stored)

proc delLeafMetadata*(
    self: RepoStore, treeCid: Cid, index: Natural
): Future[?!void] {.async: (raises: [CancelledError]).} =
  without key =? createBlockCidAndProofMetadataKey(treeCid, index), err:
    return failure(err)

  # Get the record first to have the token for CAS delete
  without record =? await get[LeafMetadata](self.metaStore, key):
    return success() # Already deleted

  ?await self.metaStore.delete(record)
  success()

proc getLeafMetadata*(
    self: RepoStore, treeCid: Cid, index: Natural
): Future[?!LeafMetadata] {.async: (raises: [CancelledError]).} =
  without key =? createBlockCidAndProofMetadataKey(treeCid, index), err:
    return failure(err)

  without record =? await get[LeafMetadata](self.metaStore, key), err:
    if err of KVStoreKeyNotFound:
      return failure(newException(BlockNotFoundError, err.msg))
    else:
      return failure(err)

  success(record.val)

proc updateTotalBlocksCount*(
    self: RepoStore, plusCount: Natural = 0, minusCount: Natural = 0
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Update total blocks count with CAS semantics

  proc middleware(
      failed: seq[Record[Natural]]
  ): Future[?!seq[Record[Natural]]] {.async: (raises: [CancelledError]).} =
    var updated: seq[Record[Natural]]
    for f in failed:
      # Re-fetch with fresh token
      if record =? await get[Natural](self.metaStore, f.key):
        let newCount = record.val + plusCount - minusCount
        updated.add(Record[Natural].init(f.key, newCount, record.token))
      else:
        # Key doesn't exist yet, create with token 0
        let newCount = plusCount - minusCount
        updated.add(Record[Natural].init(f.key, newCount, 0))
    success(updated)

  # Try to get current value
  let currentCount =
    if record =? await get[Natural](self.metaStore, ArchivistTotalBlocksKey):
      record.val
    else:
      0.Natural

  let newCount = currentCount + plusCount - minusCount
  self.totalBlocks = newCount
  archivist_repostore_blocks.set(newCount.int64)

  # Try to put with middleware for CAS retry
  let record = Record[Natural].init(ArchivistTotalBlocksKey, newCount, 0)
  ?await self.metaStore.tryPut(record, middleware = middleware)
  success()

proc updateQuotaUsage*(
    self: RepoStore,
    plusUsed: NBytes = 0.NBytes,
    minusUsed: NBytes = 0.NBytes,
    plusReserved: NBytes = 0.NBytes,
    minusReserved: NBytes = 0.NBytes,
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Update quota usage with CAS semantics

  proc middleware(
      failed: seq[Record[QuotaUsage]]
  ): Future[?!seq[Record[QuotaUsage]]] {.async: (raises: [CancelledError]).} =
    var updated: seq[Record[QuotaUsage]]
    for f in failed:
      # Re-fetch with fresh token
      let usage =
        if record =? await get[QuotaUsage](self.metaStore, f.key):
          QuotaUsage(
            used: record.val.used + plusUsed - minusUsed,
            reserved: record.val.reserved + plusReserved - minusReserved,
          )
        else:
          QuotaUsage(used: plusUsed - minusUsed, reserved: plusReserved - minusReserved)

      # Check quota limit
      if usage.used + usage.reserved > self.quotaMaxBytes:
        return failure(
          newException(
            QuotaNotEnoughError,
            "Quota usage would exceed the limit. Used: " & $usage.used & ", reserved: " &
              $usage.reserved & ", limit: " & $self.quotaMaxBytes,
          )
        )

      let token =
        if record =? await get[QuotaUsage](self.metaStore, f.key):
          record.token
        else:
          0'u64
      updated.add(Record[QuotaUsage].init(f.key, usage, token))
    success(updated)

  # Calculate new usage
  let currentUsage =
    if record =? await get[QuotaUsage](self.metaStore, QuotaUsedKey):
      record.val
    else:
      QuotaUsage(used: 0.NBytes, reserved: 0.NBytes)

  let newUsage = QuotaUsage(
    used: currentUsage.used + plusUsed - minusUsed,
    reserved: currentUsage.reserved + plusReserved - minusReserved,
  )

  # Check quota limit before attempting update
  if newUsage.used + newUsage.reserved > self.quotaMaxBytes:
    return failure(
      newException(
        QuotaNotEnoughError,
        "Quota usage would exceed the limit. Used: " & $newUsage.used & ", reserved: " &
          $newUsage.reserved & ", limit: " & $self.quotaMaxBytes,
      )
    )

  # Update in-memory cache
  self.quotaUsage = newUsage
  archivist_repostore_bytes_used.set(newUsage.used.int64)
  archivist_repostore_bytes_reserved.set(newUsage.reserved.int64)

  # Try to put with middleware for CAS retry
  let record = Record[QuotaUsage].init(QuotaUsedKey, newUsage, 0)
  ?await self.metaStore.tryPut(record, middleware = middleware)
  success()

proc updateBlockMetadata*(
    self: RepoStore, cid: Cid, plusRefCount: Natural = 0, minusRefCount: Natural = 0
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Update block metadata refcount with CAS semantics

  if cid.isEmpty:
    return success()

  without metaKey =? makeBlockMetadataKey(cid), err:
    return failure(err)

  proc middleware(
      failed: seq[Record[BlockMetadata]]
  ): Future[?!seq[Record[BlockMetadata]]] {.async: (raises: [CancelledError]).} =
    var updated: seq[Record[BlockMetadata]]
    for f in failed:
      # Re-fetch with fresh token
      without record =? await get[BlockMetadata](self.metaStore, f.key):
        return failure(
          newException(
            BlockNotFoundError, "Metadata for block with cid " & $cid & " not found"
          )
        )

      let newMeta = BlockMetadata(
        size: record.val.size,
        refCount: record.val.refCount + plusRefCount - minusRefCount,
      )
      updated.add(Record[BlockMetadata].init(f.key, newMeta, record.token))
    success(updated)

  # Get current metadata
  without record =? await get[BlockMetadata](self.metaStore, metaKey):
    return failure(
      newException(
        BlockNotFoundError, "Metadata for block with cid " & $cid & " not found"
      )
    )

  let newMeta = BlockMetadata(
    size: record.val.size, refCount: record.val.refCount + plusRefCount - minusRefCount
  )

  let newRecord = Record[BlockMetadata].init(metaKey, newMeta, record.token)
  ?await self.metaStore.tryPut(newRecord, middleware = middleware)
  success()

proc storeBlock*(
    self: RepoStore, blk: Block
): Future[?!StoreResult] {.async: (raises: [CancelledError]).} =
  ## Store a block with CAS semantics

  if blk.isEmpty:
    return success(StoreResult(kind: AlreadyInStore))

  without metaKey =? makeBlockMetadataKey(blk.cid), err:
    return failure(err)

  without blkKey =? makeBlockDataKey(blk.cid), err:
    return failure(err)

  # Check if metadata already exists
  if record =? await get[BlockMetadata](self.metaStore, metaKey):
    let currMd = record.val
    if currMd.size == blk.data.len.NBytes:
      # Block already exists with same size - verify data exists
      let hasBlock = (await self.blockStore.has(blkKey)) |? false
      if not hasBlock:
        warn "Block metadata is present, but block is absent. Restoring block.",
          cid = blk.cid
        ?await self.blockStore.put(blkKey, blk.data)

      return success(StoreResult(kind: AlreadyInStore))
    else:
      return failure(
        newException(
          CatchableError,
          "Repo already stores a block with the same cid but with a different size, cid: " &
            $blk.cid,
        )
      )

  # New block - store data first
  ?await self.blockStore.put(blkKey, blk.data)

  # Store metadata
  let md = BlockMetadata(size: blk.data.len.NBytes, refCount: 0)
  if err =? (await self.metaStore.put(metaKey, md)).errorOption:
    # Rollback: delete the block data - get record first to get token
    if blkRecord =? await get[seq[byte]](self.blockStore, blkKey):
      discard await self.blockStore.delete(blkRecord)
    return failure(err)

  success(StoreResult(kind: Stored, used: blk.data.len.NBytes))

proc tryDeleteBlock*(
    self: RepoStore, cid: Cid
): Future[?!DeleteResult] {.async: (raises: [CancelledError]).} =
  ## Delete block if refcount is 0, with CAS semantics

  without metaKey =? makeBlockMetadataKey(cid), err:
    return failure(err)

  without blkKey =? makeBlockDataKey(cid), err:
    return failure(err)

  # Get current metadata
  without record =? await get[BlockMetadata](self.metaStore, metaKey):
    # Metadata doesn't exist - check if orphan block data exists
    let hasBlock = (await self.blockStore.has(blkKey)) |? false
    if hasBlock:
      warn "Block metadata is absent, but block is present. Removing block.", cid
      if blkRecord =? await get[seq[byte]](self.blockStore, blkKey):
        discard await self.blockStore.delete(blkRecord)

    return success(DeleteResult(kind: NotFound))

  let currMd = record.val

  if currMd.refCount > 0:
    return success(DeleteResult(kind: InUse))

  # refCount == 0, delete the block
  ?await self.metaStore.delete(record)
  if blkRecord =? await get[seq[byte]](self.blockStore, blkKey):
    discard await self.blockStore.delete(blkRecord)

  success(DeleteResult(kind: Deleted, released: currMd.size))

###########################################################
# Batch Operations (Primary Implementation)
###########################################################

proc putBlocksBatch*(
    self: RepoStore, blocks: seq[Block]
): Future[?!seq[Cid]] {.async: (raises: [CancelledError]).} =
  ## Store multiple blocks with atomic metadata commit.
  ## Returns CIDs of blocks that failed (empty = all succeeded).

  # 1. Filter empty blocks
  let nonEmpty = blocks.filterIt(not it.isEmpty)
  if nonEmpty.len == 0:
    return success(newSeq[Cid]())

  # 2. Build keys for existence check
  var metaKeys: seq[Key]
  for blk in nonEmpty:
    without key =? makeBlockMetadataKey(blk.cid), err:
      return failure(err)
    metaKeys.add(key)

  # 3. Batch check which blocks already exist (returns only records for existing keys)
  let existingRecords = ?await rawkvstore.get(self.metaStore, metaKeys)
  let existingKeys = existingRecords.mapIt(it.key).toHashSet

  # 4. Identify new blocks (those whose metaKey is NOT in existingKeys)
  var newBlocks: seq[Block]
  var totalNewBytes: NBytes = 0.NBytes
  for i, blk in nonEmpty:
    if metaKeys[i] notin existingKeys:
      newBlocks.add(blk)
      totalNewBytes += blk.data.len.NBytes

  if newBlocks.len == 0:
    return success(newSeq[Cid]()) # All already exist

  # 5. CHECK QUOTA LIMIT BEFORE ANY WRITES - fail fast
  let quotaRec = await get[QuotaUsage](self.metaStore, QuotaUsedKey)
  let currentQuota =
    if quotaRec.isOk:
      quotaRec.get.val
    else:
      QuotaUsage(used: 0.NBytes, reserved: 0.NBytes)
  let quotaToken = if quotaRec.isOk: quotaRec.get.token else: 0'u64

  let projectedQuota =
    QuotaUsage(used: currentQuota.used + totalNewBytes, reserved: currentQuota.reserved)
  if projectedQuota.used + projectedQuota.reserved > self.quotaMaxBytes:
    return failure(
      newException(
        QuotaNotEnoughError,
        "Quota would be exceeded. Projected: " & $(projectedQuota.used) & ", limit: " &
          $self.quotaMaxBytes,
      )
    )

  # 6. Batch put block data (can be orphaned - not source of truth)
  var blockRecords: seq[RawRecord]
  for blk in newBlocks:
    without key =? makeBlockDataKey(blk.cid), err:
      return failure(err)
    blockRecords.add(RawRecord.init(key, blk.data, 0))

  let failedBlockKeysResult = await self.blockStore.put(blockRecords)
  if failedBlockKeysResult.isErr:
    return failure(failedBlockKeysResult.error)
  let failedBlockKeys = failedBlockKeysResult.get

  # 7. Build SINGLE ATOMIC BATCH for all metadata
  var metaRecords: seq[RawRecord]
  var actualNewBytes: NBytes = 0.NBytes
  var actualNewCount = 0

  # Add block metadata (only for blocks whose data write succeeded)
  for blk in newBlocks:
    without blkKey =? makeBlockDataKey(blk.cid), err:
      return failure(err)
    if blkKey notin failedBlockKeys:
      without metaKey =? makeBlockMetadataKey(blk.cid), err:
        return failure(err)
      let meta = BlockMetadata(size: blk.data.len.NBytes, refCount: 0)
      metaRecords.add(RawRecord.init(metaKey, encode(meta), 0))
      actualNewBytes += blk.data.len.NBytes
      actualNewCount.inc

  if actualNewCount == 0:
    # All block data writes failed
    return success(newBlocks.mapIt(it.cid))

  # Add quota record to same batch
  let finalQuota = QuotaUsage(
    used: currentQuota.used + actualNewBytes, reserved: currentQuota.reserved
  )
  metaRecords.add(RawRecord.init(QuotaUsedKey, encode(finalQuota), quotaToken))

  # Add totalBlocks record to same batch
  let totalRec = await get[Natural](self.metaStore, ArchivistTotalBlocksKey)
  let currentTotal = if totalRec.isOk: totalRec.get.val else: 0.Natural
  let totalToken = if totalRec.isOk: totalRec.get.token else: 0'u64
  metaRecords.add(
    RawRecord.init(
      ArchivistTotalBlocksKey, encode(currentTotal + actualNewCount), totalToken
    )
  )

  # 8. CAS middleware - only quota/total need refetch on conflict
  proc middleware(
      failed: seq[RawRecord]
  ): Future[?!seq[RawRecord]] {.async: (raises: [CancelledError]).} =
    var refreshed: seq[RawRecord]
    for r in failed:
      if r.key == QuotaUsedKey:
        let fresh = await get[QuotaUsage](self.metaStore, r.key)
        if fresh.isErr:
          return failure(fresh.error)
        let updated = QuotaUsage(
          used: fresh.get.val.used + actualNewBytes, reserved: fresh.get.val.reserved
        )
        if updated.used + updated.reserved > self.quotaMaxBytes:
          return failure(newException(QuotaNotEnoughError, "Quota exceeded on retry"))
        refreshed.add(RawRecord.init(r.key, encode(updated), fresh.get.token))
      elif r.key == ArchivistTotalBlocksKey:
        let fresh = await get[Natural](self.metaStore, r.key)
        if fresh.isErr:
          return failure(fresh.error)
        refreshed.add(
          RawRecord.init(r.key, encode(fresh.get.val + actualNewCount), fresh.get.token)
        )
      else:
        # Block metadata - idempotent, just retry with same data
        refreshed.add(r)
    success(refreshed)

  # 9. ATOMIC COMMIT - all metadata in single transaction
  let failedMeta = await self.metaStore.tryPut(metaRecords, middleware = middleware)
  if failedMeta.isErr:
    return failure(failedMeta.error)
  if failedMeta.get.len > 0:
    # Metadata commit failed - block data is orphaned, cleanup will handle
    return failure("Failed to commit metadata atomically")

  # 10. Update in-memory cache
  self.quotaUsage = finalQuota
  self.totalBlocks = currentTotal + actualNewCount
  archivist_repostore_blocks.set(self.totalBlocks.int64)
  archivist_repostore_bytes_used.set(finalQuota.used.int64)

  # 11. Return CIDs that failed (block data write failures)
  var failedCids: seq[Cid]
  for blk in newBlocks:
    without blkKey =? makeBlockDataKey(blk.cid), err:
      return failure(err)
    if blkKey in failedBlockKeys:
      failedCids.add(blk.cid)
  success(failedCids)

proc getBlocksBatch*(
    self: RepoStore, cids: seq[Cid]
): Future[?!seq[Block]] {.async: (raises: [CancelledError]).} =
  ## Get multiple blocks in single batch operation.

  if cids.len == 0:
    return success(newSeq[Block]())

  # Build keys and track cid->key mapping
  var keys: seq[Key]
  var cidKeyPairs: seq[(Cid, Key)] # Track which key belongs to which cid
  for cid in cids:
    if cid.isEmpty:
      continue
    without key =? makeBlockDataKey(cid), err:
      return failure(err)
    cidKeyPairs.add((cid, key))
    keys.add(key)

  # Batch get (returns only records for existing keys)
  let records = ?await rawkvstore.get(self.blockStore, keys)

  # Build key->data lookup from returned records
  var keyToData: Table[Key, seq[byte]]
  for rec in records:
    keyToData[rec.key] = rec.val

  # Build blocks in original order
  var blocks: seq[Block]
  for cid in cids:
    if cid.isEmpty:
      without emptyBlk =? cid.emptyBlock, err:
        return failure(err)
      blocks.add(emptyBlk)
    else:
      without key =? makeBlockDataKey(cid), err:
        return failure(err)
      if not keyToData.hasKey(key):
        return failure(newException(BlockNotFoundError, "Block not found: " & $cid))
      without blk =? Block.new(cid, keyToData.getOrDefault(key), verify = true), err:
        return failure(err)
      blocks.add(blk)

  success(blocks)

proc delBlocksBatch*(
    self: RepoStore, cids: seq[Cid]
): Future[?!seq[Cid]] {.async: (raises: [CancelledError]).} =
  ## Delete multiple blocks with atomic metadata commit.
  ## Returns CIDs that were actually deleted (had refCount == 0).

  if cids.len == 0:
    return success(newSeq[Cid]())

  # 1. Build keys and cid mapping
  var metaKeys: seq[Key]
  var cidToKey: seq[(Cid, Key)]
  for cid in cids:
    if cid.isEmpty:
      continue
    without key =? makeBlockMetadataKey(cid), err:
      return failure(err)
    cidToKey.add((cid, key))
    metaKeys.add(key)

  if metaKeys.len == 0:
    return success(newSeq[Cid]())

  # Batch get metadata (returns only records for existing keys)
  let metaRecords = ?await rawkvstore.get(self.metaStore, metaKeys)

  # Build key->record lookup
  var keyToRecord: Table[Key, RawRecord]
  for rec in metaRecords:
    keyToRecord[rec.key] = rec

  # 2. Identify blocks to delete (refCount == 0)
  var toDelete: seq[KeyRecord]
  var cidsToDelete: seq[Cid]
  var bytesReleased: NBytes = 0.NBytes
  var keyToMeta: Table[Key, BlockMetadata] # For later use

  for (cid, key) in cidToKey:
    if keyToRecord.hasKey(key):
      let rec = keyToRecord.getOrDefault(key)
      without meta =? BlockMetadata.decode(rec.val), err:
        return failure(err)
      keyToMeta[key] = meta
      if meta.refCount == 0:
        toDelete.add(KeyRecord(key: key, token: rec.token))
        cidsToDelete.add(cid)
        bytesReleased += meta.size

  if toDelete.len == 0:
    return success(newSeq[Cid]())

  # 3. Get current quota and totalBlocks for atomic update
  let quotaRec = await get[QuotaUsage](self.metaStore, QuotaUsedKey)
  let currentQuota =
    if quotaRec.isOk:
      quotaRec.get.val
    else:
      QuotaUsage(used: 0.NBytes, reserved: 0.NBytes)
  let quotaToken = if quotaRec.isOk: quotaRec.get.token else: 0'u64

  let totalRec = await get[Natural](self.metaStore, ArchivistTotalBlocksKey)
  let currentTotal = if totalRec.isOk: totalRec.get.val else: 0.Natural
  let totalToken = if totalRec.isOk: totalRec.get.token else: 0'u64

  # 4. Atomic delete of metadata records
  proc deleteMiddleware(
      failed: seq[KeyRecord]
  ): Future[?!seq[KeyRecord]] {.async: (raises: [CancelledError]).} =
    var refreshed: seq[KeyRecord]
    for r in failed:
      let rec = await get[BlockMetadata](self.metaStore, r.key)
      if rec.isOk and rec.get.val.refCount == 0:
        refreshed.add(KeyRecord(key: r.key, token: rec.get.token))
    success(refreshed)

  let failedDeletesResult =
    await self.metaStore.tryDelete(toDelete, middleware = deleteMiddleware)
  if failedDeletesResult.isErr:
    return failure(failedDeletesResult.error)
  let failedDeletes = failedDeletesResult.get

  # Calculate actual deletions
  let actualDeleted = toDelete.len - failedDeletes.len
  if actualDeleted == 0:
    return success(newSeq[Cid]())

  # Adjust bytes for failed deletes
  var actualBytesReleased = bytesReleased
  let failedKeys = failedDeletes.mapIt(it.key).toHashSet
  for (cid, key) in cidToKey:
    if key in failedKeys and keyToMeta.hasKey(key):
      actualBytesReleased -= keyToMeta.getOrDefault(key).size

  # 5. Atomic update of quota + totalBlocks
  let newQuota = QuotaUsage(
    used: currentQuota.used - actualBytesReleased, reserved: currentQuota.reserved
  )
  let newTotal = currentTotal - actualDeleted

  var updateRecords: seq[RawRecord]
  updateRecords.add(RawRecord.init(QuotaUsedKey, encode(newQuota), quotaToken))
  updateRecords.add(
    RawRecord.init(ArchivistTotalBlocksKey, encode(newTotal), totalToken)
  )

  proc updateMiddleware(
      failed: seq[RawRecord]
  ): Future[?!seq[RawRecord]] {.async: (raises: [CancelledError]).} =
    var refreshed: seq[RawRecord]
    for r in failed:
      if r.key == QuotaUsedKey:
        let fresh = await get[QuotaUsage](self.metaStore, r.key)
        if fresh.isErr:
          return failure(fresh.error)
        let updated = QuotaUsage(
          used: fresh.get.val.used - actualBytesReleased,
          reserved: fresh.get.val.reserved,
        )
        refreshed.add(RawRecord.init(r.key, encode(updated), fresh.get.token))
      elif r.key == ArchivistTotalBlocksKey:
        let fresh = await get[Natural](self.metaStore, r.key)
        if fresh.isErr:
          return failure(fresh.error)
        refreshed.add(
          RawRecord.init(r.key, encode(fresh.get.val - actualDeleted), fresh.get.token)
        )
    success(refreshed)

  discard await self.metaStore.tryPut(updateRecords, middleware = updateMiddleware)

  # 6. Update in-memory cache
  self.quotaUsage = newQuota
  self.totalBlocks = newTotal
  archivist_repostore_blocks.set(newTotal.int64)
  archivist_repostore_bytes_used.set(newQuota.used.int64)

  # 7. Batch delete block data (best effort - orphan cleanup handles failures)
  var blockKeys: seq[Key]
  for cid in cidsToDelete:
    without metaKey =? makeBlockMetadataKey(cid), err:
      continue
    if metaKey notin failedKeys:
      without blkKey =? makeBlockDataKey(cid), err:
        continue
      blockKeys.add(blkKey)

  if blockKeys.len > 0:
    let blockRecords = await rawkvstore.get(self.blockStore, blockKeys)
    if blockRecords.isOk:
      let toDeleteBlocks =
        blockRecords.get.mapIt(KeyRecord(key: it.key, token: it.token))
      discard await self.blockStore.delete(toDeleteBlocks)

  # 8. Return CIDs that were actually deleted
  var deletedCids: seq[Cid]
  for cid in cidsToDelete:
    if metaKey =? makeBlockMetadataKey(cid):
      if metaKey notin failedKeys:
        deletedCids.add(cid)
  success(deletedCids)

proc batchUpdateRefcounts*(
    self: RepoStore, updates: seq[(Cid, int)]
): Future[?!seq[Cid]] {.async: (raises: [CancelledError]).} =
  ## Atomically update refcounts for multiple blocks.
  ## Returns CIDs of blocks that reached refCount == 0 (ready for deletion).

  if updates.len == 0:
    return success(newSeq[Cid]())

  # Build keys and mapping
  var metaKeys: seq[Key]
  var cidDeltas: seq[(Cid, int, Key)] # (cid, delta, key)
  for (cid, delta) in updates:
    if cid.isEmpty:
      continue
    without key =? makeBlockMetadataKey(cid), err:
      return failure(err)
    cidDeltas.add((cid, delta, key))
    metaKeys.add(key)

  if metaKeys.len == 0:
    return success(newSeq[Cid]())

  # Batch get metadata (returns only records for existing keys)
  let metaRecords = ?await rawkvstore.get(self.metaStore, metaKeys)

  # Build key->record lookup
  var keyToRecord: Table[Key, RawRecord]
  for rec in metaRecords:
    keyToRecord[rec.key] = rec

  # Build update records (only for blocks that exist)
  var toUpdate: seq[RawRecord]
  var zeroRefCids: seq[Cid]

  for (cid, delta, key) in cidDeltas:
    if keyToRecord.hasKey(key):
      let rec = keyToRecord.getOrDefault(key)
      without meta =? BlockMetadata.decode(rec.val), err:
        return failure(err)
      let newRefCount = max(0, meta.refCount.int + delta).Natural
      let newMeta = BlockMetadata(size: meta.size, refCount: newRefCount)
      toUpdate.add(RawRecord.init(key, encode(newMeta), rec.token))
      if newRefCount == 0:
        zeroRefCids.add(cid)

  if toUpdate.len == 0:
    return success(newSeq[Cid]())

  # CAS middleware for refetch on conflict
  proc middleware(
      failed: seq[RawRecord]
  ): Future[?!seq[RawRecord]] {.async: (raises: [CancelledError]).} =
    var refreshed: seq[RawRecord]
    for r in failed:
      # Find the delta for this key
      var delta = 0
      for (_, d, key) in cidDeltas:
        if key == r.key:
          delta = d
          break

      let fresh = await get[BlockMetadata](self.metaStore, r.key)
      if fresh.isOk:
        let newRefCount = max(0, fresh.get.val.refCount.int + delta).Natural
        let newMeta = BlockMetadata(size: fresh.get.val.size, refCount: newRefCount)
        refreshed.add(RawRecord.init(r.key, encode(newMeta), fresh.get.token))
    success(refreshed)

  let failedResult = await self.metaStore.tryPut(toUpdate, middleware = middleware)
  if failedResult.isErr:
    return failure(failedResult.error)

  success(zeroRefCids)
