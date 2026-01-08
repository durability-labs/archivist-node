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

import pkg/chronos
import pkg/chronos/futures
import pkg/kvstore
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
