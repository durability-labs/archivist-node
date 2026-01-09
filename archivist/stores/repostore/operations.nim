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

###########################################################
# Internal Helpers
###########################################################

type CounterDelta* = object
  ## Represents changes to quota and totalBlocks counters
  ## Uses int64 for deltas since they can be negative (for deletions)
  quotaUsedDelta*: int64
  quotaReservedDelta*: int64
  totalBlocksDelta*: int

proc getWithDefault*[T](
    store: KVStore, key: Key, default: T
): Future[?!(T, uint64)] {.async: (raises: [CancelledError]).} =
  ## Get value with token, or default with token=0
  if record =? await get[T](store, key):
    success((record.val, record.token))
  else:
    success((default, 0'u64))

proc validateQuotaLimit*(usage: QuotaUsage, limit: NBytes): ?!void =
  ## Check if quota usage is within limit
  if usage.used + usage.reserved > limit:
    failure(
      newException(
        QuotaNotEnoughError,
        "Quota exceeded: used=" & $usage.used & ", reserved=" & $usage.reserved &
          ", limit=" & $limit,
      )
    )
  else:
    success()

proc buildKeyLookup*(records: seq[RawRecord]): Table[Key, RawRecord] =
  ## Convert batch get results to key -> record lookup
  result = initTable[Key, RawRecord]()
  for rec in records:
    result[rec.key] = rec

proc updateMetrics*(self: RepoStore) =
  ## Update prometheus metrics from in-memory cache
  archivist_repostore_blocks.set(self.totalBlocks.int64)
  archivist_repostore_bytes_used.set(self.quotaUsage.used.int64)
  archivist_repostore_bytes_reserved.set(self.quotaUsage.reserved.int64)

type CounterMiddleware* = proc(failed: seq[RawRecord]): Future[?!seq[RawRecord]] {.
  async: (raises: [CancelledError])
.}

proc makeCounterMiddleware*(
    self: RepoStore, quotaDeltaBytes: int64, totalDelta: int
): CounterMiddleware =
  ## Factory for CAS middleware that handles counter updates on conflict.
  ## Handles QuotaUsedKey and ArchivistTotalBlocksKey, passes through other records unchanged.
  ## quotaDeltaBytes can be positive (add) or negative (subtract).
  proc middleware(
      failed: seq[RawRecord]
  ): Future[?!seq[RawRecord]] {.async: (raises: [CancelledError]).} =
    var refreshed: seq[RawRecord]
    for r in failed:
      if r.key == QuotaUsedKey:
        let (fresh, token) =
          ?await getWithDefault[QuotaUsage](
            self.metaStore, r.key, QuotaUsage(used: 0.NBytes, reserved: 0.NBytes)
          )
        let newUsed = max(0'i64, fresh.used.int64 + quotaDeltaBytes).NBytes
        let updated = QuotaUsage(used: newUsed, reserved: fresh.reserved)
        ?validateQuotaLimit(updated, self.quotaMaxBytes)
        refreshed.add(RawRecord.init(r.key, encode(updated), token))
      elif r.key == ArchivistTotalBlocksKey:
        let (fresh, token) =
          ?await getWithDefault[Natural](self.metaStore, r.key, 0.Natural)
        let updatedTotal = max(0, fresh.int + totalDelta).Natural
        refreshed.add(RawRecord.init(r.key, encode(updatedTotal), token))
      else:
        # Block metadata or other records - idempotent, just retry with same data
        refreshed.add(r)
    success(refreshed)

  middleware

proc updateCountersAtomic*(
    self: RepoStore, delta: CounterDelta
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Atomically update quota and totalBlocks counters with CAS retry
  ## This is the single source of truth for counter updates

  # Get current values with tokens
  let (currentQuota, quotaToken) =
    ?await getWithDefault[QuotaUsage](
      self.metaStore, QuotaUsedKey, QuotaUsage(used: 0.NBytes, reserved: 0.NBytes)
    )
  let (currentTotal, totalToken) =
    ?await getWithDefault[Natural](self.metaStore, ArchivistTotalBlocksKey, 0.Natural)

  # Validate that deltas don't make values negative (preserve RangeDefect behavior)
  let newUsedRaw = currentQuota.used.int64 + delta.quotaUsedDelta
  let newReservedRaw = currentQuota.reserved.int64 + delta.quotaReservedDelta
  let newTotalRaw = currentTotal.int + delta.totalBlocksDelta

  if newReservedRaw < 0:
    raise newException(
      RangeDefect,
      "Cannot release more bytes than reserved: current=" & $currentQuota.reserved &
        ", delta=" & $delta.quotaReservedDelta,
    )

  # Calculate new values (used and total can be clamped safely)
  let newQuota =
    QuotaUsage(used: max(0'i64, newUsedRaw).NBytes, reserved: newReservedRaw.NBytes)
  let newTotal = max(0, newTotalRaw).Natural

  # Validate quota limit
  ?validateQuotaLimit(newQuota, self.quotaMaxBytes)

  # Build records for atomic batch
  var records: seq[RawRecord]
  records.add(RawRecord.init(QuotaUsedKey, encode(newQuota), quotaToken))
  records.add(RawRecord.init(ArchivistTotalBlocksKey, encode(newTotal), totalToken))

  # CAS middleware for retry on conflict
  proc middleware(
      failed: seq[RawRecord]
  ): Future[?!seq[RawRecord]] {.async: (raises: [CancelledError]).} =
    var refreshed: seq[RawRecord]
    for r in failed:
      if r.key == QuotaUsedKey:
        let (fresh, token) =
          ?await getWithDefault[QuotaUsage](
            self.metaStore, r.key, QuotaUsage(used: 0.NBytes, reserved: 0.NBytes)
          )
        let updated = QuotaUsage(
          used: max(0'i64, fresh.used.int64 + delta.quotaUsedDelta).NBytes,
          reserved: max(0'i64, fresh.reserved.int64 + delta.quotaReservedDelta).NBytes,
        )
        ?validateQuotaLimit(updated, self.quotaMaxBytes)
        refreshed.add(RawRecord.init(r.key, encode(updated), token))
      elif r.key == ArchivistTotalBlocksKey:
        let (fresh, token) =
          ?await getWithDefault[Natural](self.metaStore, r.key, 0.Natural)
        let updatedTotal = max(0, fresh.int + delta.totalBlocksDelta).Natural
        refreshed.add(RawRecord.init(r.key, encode(updatedTotal), token))
    success(refreshed)

  let failedResult = await self.metaStore.tryPut(records, middleware = middleware)
  if failedResult.isErr:
    return failure(failedResult.error)
  if failedResult.get.len > 0:
    return failure("Failed to update counters atomically")

  # Update in-memory cache
  self.quotaUsage = newQuota
  self.totalBlocks = newTotal
  self.updateMetrics()

  success()

###########################################################
# Leaf Metadata Operations
###########################################################

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

###########################################################
# Batch Operations (Primary Implementation)
###########################################################

proc putBlocksBatch*(
    self: RepoStore, blocks: seq[Block]
): Future[?!seq[Cid]] {.async: (raises: [CancelledError]).} =
  ## Store multiple blocks with atomic metadata commit.
  ## Returns CIDs of blocks that failed (empty = all succeeded).

  # 1. NORMALIZE: Filter empty blocks and build keys
  let nonEmpty = blocks.filterIt(not it.isEmpty)
  if nonEmpty.len == 0:
    return success(newSeq[Cid]())

  var metaKeys: seq[Key]
  for blk in nonEmpty:
    without key =? makeBlockMetadataKey(blk.cid), err:
      return failure(err)
    metaKeys.add(key)

  # 2. Batch check which blocks already exist
  let existingRecords = ?await rawkvstore.get(self.metaStore, metaKeys)
  let existingKeys = existingRecords.mapIt(it.key).toHashSet

  # 3. Identify new blocks
  var newBlocks: seq[Block]
  var totalNewBytes: NBytes = 0.NBytes
  for i, blk in nonEmpty:
    if metaKeys[i] notin existingKeys:
      newBlocks.add(blk)
      totalNewBytes += blk.data.len.NBytes

  if newBlocks.len == 0:
    return success(newSeq[Cid]())

  # 4. PREFLIGHT: Check quota limit before any writes
  let (currentQuota, quotaToken) =
    ?await getWithDefault[QuotaUsage](
      self.metaStore, QuotaUsedKey, QuotaUsage(used: 0.NBytes, reserved: 0.NBytes)
    )
  let projectedQuota =
    QuotaUsage(used: currentQuota.used + totalNewBytes, reserved: currentQuota.reserved)
  ?validateQuotaLimit(projectedQuota, self.quotaMaxBytes)

  # 5. COMMIT: Write block data (can be orphaned - not source of truth)
  var blockRecords: seq[RawRecord]
  for blk in newBlocks:
    without key =? makeBlockDataKey(blk.cid), err:
      return failure(err)
    blockRecords.add(RawRecord.init(key, blk.data, 0))

  let failedBlockKeys = ?await self.blockStore.put(blockRecords)

  # 6. Build atomic metadata batch
  var metaRecords: seq[RawRecord]
  var actualNewBytes: NBytes = 0.NBytes
  var actualNewCount = 0

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
    return success(newBlocks.mapIt(it.cid))

  # 7. Add counter records to same batch
  let finalQuota = QuotaUsage(
    used: currentQuota.used + actualNewBytes, reserved: currentQuota.reserved
  )
  metaRecords.add(RawRecord.init(QuotaUsedKey, encode(finalQuota), quotaToken))

  let (currentTotal, totalToken) =
    ?await getWithDefault[Natural](self.metaStore, ArchivistTotalBlocksKey, 0.Natural)
  metaRecords.add(
    RawRecord.init(
      ArchivistTotalBlocksKey, encode(currentTotal + actualNewCount), totalToken
    )
  )

  # 8. Atomic commit with CAS middleware
  let middleware = self.makeCounterMiddleware(actualNewBytes.int64, actualNewCount)
  let failedMeta = ?await self.metaStore.tryPut(metaRecords, middleware = middleware)
  if failedMeta.len > 0:
    return failure("Failed to commit metadata atomically")

  # 9. Update cache and metrics
  self.quotaUsage = finalQuota
  self.totalBlocks = currentTotal + actualNewCount
  self.updateMetrics()

  # 10. Return failed CIDs
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

  # 1. NORMALIZE: Build keys and cid mapping
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

  # 2. Batch get metadata and build lookup
  let metaRecords = ?await rawkvstore.get(self.metaStore, metaKeys)
  let keyToRecord = buildKeyLookup(metaRecords)

  # 3. Identify blocks to delete (refCount == 0)
  var toDelete: seq[KeyRecord]
  var cidsToDelete: seq[Cid]
  var bytesReleased: NBytes = 0.NBytes
  var keyToMeta: Table[Key, BlockMetadata]

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

  # 4. Delete middleware for metadata records
  proc deleteMiddleware(
      failed: seq[KeyRecord]
  ): Future[?!seq[KeyRecord]] {.async: (raises: [CancelledError]).} =
    var refreshed: seq[KeyRecord]
    for r in failed:
      let rec = await get[BlockMetadata](self.metaStore, r.key)
      if rec.isOk and rec.get.val.refCount == 0:
        refreshed.add(KeyRecord(key: r.key, token: rec.get.token))
    success(refreshed)

  # 5. COMMIT: Atomic delete of metadata records
  let failedDeletes =
    ?await self.metaStore.tryDelete(toDelete, middleware = deleteMiddleware)

  let actualDeleted = toDelete.len - failedDeletes.len
  if actualDeleted == 0:
    return success(newSeq[Cid]())

  # Calculate actual bytes released
  var actualBytesReleased = bytesReleased
  let failedKeys = failedDeletes.mapIt(it.key).toHashSet
  for (_, key) in cidToKey:
    if key in failedKeys and keyToMeta.hasKey(key):
      actualBytesReleased -= keyToMeta.getOrDefault(key).size

  # 6. Atomic update of quota + totalBlocks
  let (currentQuota, quotaToken) =
    ?await getWithDefault[QuotaUsage](
      self.metaStore, QuotaUsedKey, QuotaUsage(used: 0.NBytes, reserved: 0.NBytes)
    )
  let (currentTotal, totalToken) =
    ?await getWithDefault[Natural](self.metaStore, ArchivistTotalBlocksKey, 0.Natural)

  let newQuota = QuotaUsage(
    used: max(0'i64, currentQuota.used.int64 - actualBytesReleased.int64).NBytes,
    reserved: currentQuota.reserved,
  )
  let newTotal = max(0, currentTotal.int - actualDeleted).Natural

  var updateRecords: seq[RawRecord]
  updateRecords.add(RawRecord.init(QuotaUsedKey, encode(newQuota), quotaToken))
  updateRecords.add(
    RawRecord.init(ArchivistTotalBlocksKey, encode(newTotal), totalToken)
  )

  let middleware =
    self.makeCounterMiddleware(-actualBytesReleased.int64, -actualDeleted)
  discard await self.metaStore.tryPut(updateRecords, middleware = middleware)

  # 7. Update cache and metrics
  self.quotaUsage = newQuota
  self.totalBlocks = newTotal
  self.updateMetrics()

  # 8. Batch delete block data (best effort - orphan cleanup handles failures)
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

  # 9. Return CIDs that were actually deleted
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

  # 1. NORMALIZE: Build keys and mapping
  var metaKeys: seq[Key]
  var cidDeltas: seq[(Cid, int, Key)]
  for (cid, delta) in updates:
    if cid.isEmpty:
      continue
    without key =? makeBlockMetadataKey(cid), err:
      return failure(err)
    cidDeltas.add((cid, delta, key))
    metaKeys.add(key)

  if metaKeys.len == 0:
    return success(newSeq[Cid]())

  # 2. Batch get metadata and build lookup
  let metaRecords = ?await rawkvstore.get(self.metaStore, metaKeys)
  let keyToRecord = buildKeyLookup(metaRecords)

  # 3. Build update records (only for blocks that exist)
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

  # 4. CAS middleware for refetch on conflict
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

  # 5. COMMIT
  discard ?await self.metaStore.tryPut(toUpdate, middleware = middleware)
  success(zeroRefCids)

###########################################################
# Single Operations (Wrappers around batch/atomic operations)
###########################################################

proc updateTotalBlocksCount*(
    self: RepoStore, plusCount: Natural = 0, minusCount: Natural = 0
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Update total blocks count - wrapper around updateCountersAtomic
  let delta = CounterDelta(
    quotaUsedDelta: 0'i64,
    quotaReservedDelta: 0'i64,
    totalBlocksDelta: plusCount.int - minusCount.int,
  )
  await self.updateCountersAtomic(delta)

proc updateQuotaUsage*(
    self: RepoStore,
    plusUsed: NBytes = 0.NBytes,
    minusUsed: NBytes = 0.NBytes,
    plusReserved: NBytes = 0.NBytes,
    minusReserved: NBytes = 0.NBytes,
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Update quota usage - wrapper around updateCountersAtomic
  let delta = CounterDelta(
    quotaUsedDelta: plusUsed.int64 - minusUsed.int64,
    quotaReservedDelta: plusReserved.int64 - minusReserved.int64,
    totalBlocksDelta: 0,
  )
  await self.updateCountersAtomic(delta)

proc updateBlockMetadata*(
    self: RepoStore, cid: Cid, plusRefCount: Natural = 0, minusRefCount: Natural = 0
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Update block metadata refcount - wrapper around batchUpdateRefcounts
  if cid.isEmpty:
    return success()
  let delta = plusRefCount.int - minusRefCount.int
  discard ?await self.batchUpdateRefcounts(@[(cid, delta)])
  success()

proc storeBlock*(
    self: RepoStore, blk: Block
): Future[?!StoreResult] {.async: (raises: [CancelledError]).} =
  ## Store a single block with proper return type
  if blk.isEmpty:
    return success(StoreResult(kind: AlreadyInStore))

  # Check if already exists (for proper return value)
  without metaKey =? makeBlockMetadataKey(blk.cid), err:
    return failure(err)

  if record =? await get[BlockMetadata](self.metaStore, metaKey):
    let currMd = record.val
    if currMd.size == blk.data.len.NBytes:
      # Block exists - verify data exists (orphan recovery)
      without blkKey =? makeBlockDataKey(blk.cid), err:
        return failure(err)
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

  # Delegate to batch operation
  let failed = ?await self.putBlocksBatch(@[blk])
  if blk.cid in failed:
    return failure("Failed to store block")
  success(StoreResult(kind: Stored, used: blk.data.len.NBytes))

proc tryDeleteBlock*(
    self: RepoStore, cid: Cid
): Future[?!DeleteResult] {.async: (raises: [CancelledError]).} =
  ## Delete block if refcount is 0 - with proper return type
  without metaKey =? makeBlockMetadataKey(cid), err:
    return failure(err)

  without blkKey =? makeBlockDataKey(cid), err:
    return failure(err)

  # Check metadata for proper return value
  without record =? await get[BlockMetadata](self.metaStore, metaKey):
    # Metadata doesn't exist - check for orphan block data
    let hasBlock = (await self.blockStore.has(blkKey)) |? false
    if hasBlock:
      warn "Block metadata is absent, but block is present. Removing block.", cid
      if blkRecord =? await get[seq[byte]](self.blockStore, blkKey):
        discard await self.blockStore.delete(blkRecord)
    return success(DeleteResult(kind: NotFound))

  let currMd = record.val
  if currMd.refCount > 0:
    return success(DeleteResult(kind: InUse))

  # Delegate to batch operation
  let deleted = ?await self.delBlocksBatch(@[cid])
  if cid in deleted:
    success(DeleteResult(kind: Deleted, released: currMd.size))
  else:
    success(DeleteResult(kind: InUse)) # Refcount changed concurrently
