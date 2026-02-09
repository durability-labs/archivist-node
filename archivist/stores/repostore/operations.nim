## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2024 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/tables
import std/sugar

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
import ../../clock
import ../../logutils
import ../../merkletree

logScope:
  topics = "archivist repostore"

declareGauge(archivist_repostore_blocks, "archivist repostore blocks")
declareGauge(archivist_repostore_bytes_used, "archivist repostore bytes used")
declareGauge(archivist_repostore_bytes_reserved, "archivist repostore bytes reserved")

## NOTE: It's very important that we understand the general flow and order of operations
## and their guarantees.
##
## We have two stores - metadata (metaDs) and blockstore (repoDs), backed by KVStores
## with potentialy different guarantees, this can lead to subtle bugs if we do not
## understand what those are.
##
## The KVStore provides CAS (compare-and-swap) semantics, as well as batched atomic
## operations (atomic*). However, the atomic operations are only available on the sqlite
## (and potentialy others in the future) backend, the FS backend, which is used for the
## on disk blocks, only has CAS semantics and it doesn't support atomic opperations
## (it will raise at runtime - parhaps we can make this compile time as well). By CAS
## semantics we mean that we won't update stale records, but it doesn't mean that a
## multikey updates will remain consistent, this is only guaranteed by atomic operations.
##
## This allows us to preserve consistency even in the event of crashes, however this
## requires care with the order of operations. The metadata store support atomic operations
## but the block store doesn't, which means that we should avoid writing blocks to the
## filesystem before writing the metadata, because that would require expensive filesystem
## scans (which we used to do!) to find orphaned blocks. If we write the metadata first
## however, we can always recover from missing on disk block, by either re-downloading or
## dropping the meta entry.
##
## For the metadata writes:
## - ALWAYS WRITE BOTH LEAFS AND BLOCK META (refCount) AS AN ATOMIC BATCH, and only after
## updating the metadata (both leafs and counters and anything else that requires consistency
## per block) write the block on disk.
##
## For the counter updates:
## - ALWAYS USE ATOMIC WRITES to avoid inconsistent updates. Only block store writes
## (i.e. writing the block to disk) should affect the blockcount and quota values, metadata
## should never touch those.
##

proc updateCounters*(
    self: RepoStore, quotaDelta = 0, reservedDelta = 0, blocksDelta = 0
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Update counters
  ##

  let updates =
    @[
      KVRecord[QuotaUsage].init(
        QuotaUsedKey,
        QuotaUsage(
          used: max(0, quotaDelta).NBytes, reserved: max(0, reservedDelta).NBytes
        ),
      ).toRaw,
      KVRecord[Natural].init(ArchivistTotalBlocksKey, max(0, blocksDelta).Natural).toRaw,
    ]

  # NOTE: We always attempt to insert with default values first,
  # and rely on retries to perform the actual update
  proc updateCountersMiddleware(
      records: seq[RawKVRecord], conflicts: seq[Key]
  ): Future[?!seq[RawKVRecord]] {.async: (raises: [CancelledError]), gcsafe.} =
    var refreshed = (?await self.metaDs.get(conflicts)).mapIt((it.key, it)).toTable

    for record in toSeq(refreshed.values):
      if record.key == QuotaUsedKey:
        var
          quotaRec = ?toRecord[QuotaUsage](record)
          quotaUsed = max(0, (quotaRec.val.used.int + quotaDelta)).NBytes
          quotaReserved = max(0, (quotaRec.val.reserved.int + reservedDelta)).NBytes
        trace "Updating quota to", quotaUsed, quotaReserved

        quotaRec.val.used = quotaUsed
        quotaRec.val.reserved = quotaReserved
        refreshed[record.key] = quotaRec.toRaw
      elif record.key == ArchivistTotalBlocksKey:
        var
          totalBlocksRec = ?toRecord[Natural](record)
          totalBlocks = max(0, totalBlocksRec.val.int + blocksDelta).Natural
        trace "Updating block count to", totalBlocks

        totalBlocksRec.val = totalBlocks
        refreshed[record.key] = totalBlocksRec.toRaw
      else:
        return failure("Unrecongized key! " & $record.key)

    success toSeq(refreshed.values)

  trace "Updating counters", quotaDelta, reservedDelta, blocksDelta
  ?await self.metaDs.tryPutAtomic(updates, maxRetries = 3, updateCountersMiddleware)

  if quotaDelta != 0:
    self.quotaUsage.used = (self.quotaUsage.used.int + quotaDelta).NBytes
    archivist_repostore_bytes_used.set(self.quotaUsage.used.int64)

  if reservedDelta != 0:
    self.quotaUsage.reserved = (self.quotaUsage.reserved.int + reservedDelta).NBytes
    archivist_repostore_bytes_reserved.set(self.quotaUsage.reserved.int64)

  if blocksDelta != 0:
    self.totalBlocks = (self.totalBlocks.int + blocksDelta).Natural
    archivist_repostore_blocks.set(self.totalBlocks.int64)

  success()

proc deleteBlocksMetaRecs*(
    self: RepoStore,
    blocksMeta: seq[KVRecord[BlockMetadata]],
    blockSize = DefaultBlockSize,
): Future[?!seq[KVRecord[BlockMetadata]]] {.async: (raises: [CancelledError]).} =
  ## Delete blocks and metadata for refCount == 0
  ##
  ## Return skipped Records or empty seq if none were skipped
  ##

  trace "Deleting blocks metadata", count = blocksMeta.len
  # delete meta keys
  await self.metaDs.tryDelete(
    blocksMeta.filterIt(it.val.refCount == 0), # never delete if refCount != 0
    maxRetries = 3,
    proc(
        records: seq[KVRecord[BlockMetadata]]
    ): Future[?!seq[KVRecord[BlockMetadata]]] {.async: (raises: [CancelledError]).} =
      let refreshed = (?await self.metaDs.get(records.mapIt(it.key), BlockMetadata)).filterIt(
        it.val.refCount == 0 # never delete if refCount != 0
      )

      trace "Refreshed record for block metadata", count = refreshed.len
      success refreshed
    ,
  )

proc delFromBlocksStore*(
    self: RepoStore, cids: seq[Cid]
): Future[?!seq[Cid]] {.async: (raises: [CancelledError]).} =
  ## Delete from local block store
  ##

  trace "Deleting from block store", count = cids.len
  let
    deduped = cids.deduplicate().filterIt(not it.isEmpty)
    keys = deduped.mapIt(?makePrefixKey(self.postFixLen, it))

    # get fs blocks first, we need a valid KVRecord.token -
    # (we should have a `drop` method in the kvstore, that
    # bypases CAS for cituations like this)
    toDelete = ?await self.repoDs.get(keys)

    # delete on disk blocks first  - best effort if crash
    # occurs we might miss some blocks, but we can recover
    # the delete, since the metadata is still present
    skipped = (?await self.repoDs.delete(toDelete.toKeyRecord)).toHashSet

    # Update counters
    deletedCount = toDelete.len - skipped.len

  var deletedSize = 0
  for record in toDelete:
    if record.key in skipped:
      continue

    deletedSize += record.val.len

  ?await self.updateCounters(quotaDelta = -(deletedSize), blocksDelta = -(deletedCount))
  return success skipped.mapIt(?Cid.init(it.value).mapFailure)

proc tryDeleteBlocks*(
    self: RepoStore, cids: seq[Cid], blockSize = DefaultBlockSize
): Future[?!seq[Cid]] {.async: (raises: [CancelledError]).} =
  ## We only delete the block if no metadata is present
  ## OR the refCount is 0
  ##
  ## Returns skipped cids or empty seq
  ##
  ## TODO: Currently, we're not respecting the refCount invariance
  ## during deletion, because blocks can still be put without any
  ## metadata, however once we introduce the overlays, this will
  ## no longer be the case, even blocks that don't have a merkle
  ## tree yet, will get metdata and a respective refCount
  ##

  trace "Deleting blocks", count = cids.len

  let
    dedupped = cids.deduplicate().filterIt(not it.isEmpty)
    # delete fs blocks first - drop the block, we'll rework with
    # refCount once overlays are ready
    skippedCids = ?await self.delFromBlocksStore(dedupped)
    # only delete metadata for deleted fs blocks (cid - skipped cids)
    blockMetaKeys =
      (dedupped.toHashset - skippedCids.toHashSet).mapIt((?blockMetaKey(it)))
    # this will happen before deleting the fs block once we have overlays
    blocksMeta = ?await self.metaDs.get(blockMetaKeys, BlockMetadata)
    skipped = ?await self.deleteBlocksMetaRecs(blocksMeta)

  # return skipped Cids
  success toSeq(
    cids.toHashSet - skipped.mapIt(?Cid.init(it.key.value).mapFailure).toHashSet
  )

proc tryDeleteBlocks*(
    self: RepoStore, cid: Cid, blockSize = DefaultBlockSize
): Future[?!seq[Cid]] {.async: (raises: [CancelledError], raw: true).} =
  self.tryDeleteBlocks(@[cid])

type BlockLeafTuple* =
  tuple[
    index: Natural, blkCid: Cid, proof: ArchivistProof, blockSize = DefaultBlockSize
  ]

proc putOrUpdateLeafBlockMeta*(
    self: RepoStore, treeCid: Cid, blocks: seq[BlockLeafTuple]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Put or update lef and block metadata
  ##

  let updates = blocks
    .deduplicate()
    .mapIt(
      @[
        KVRecord[LeafMetadata].init(
          ?blockProofKey(treeCid, it.index),
          LeafMetadata(blkCid: it.blkCid, proof: it.proof),
        ).toRaw,
        KVRecord[BlockMetadata].init(
          ?blockMetaKey(it.blkCid),
          BlockMetadata(refCount: 1, cid: it.blkCid, size: it.blockSize),
        ).toRaw,
      ]
    ).concat

  proc putLeafAndBlockMetaAtomic(
      records: seq[RawKVRecord], conflicts: seq[Key]
  ): Future[?!seq[RawKVRecord]] {.async: (raises: [CancelledError]), gcsafe.} =
    var records = records.mapIt((it.key, it)).toTable
    let refreshed = ?await self.metaDs.get(conflicts)

    trace "Got refreshed leaf and block records",
      refreshed = refreshed.len, conflicts = conflicts.len

    for rec in refreshed:
      var record = rec

      trace "Processing record", key = record.key
      if BlocksMetaKey.ancestor(record.key):
        var blockMeta = ?toRecord[BlockMetadata](record)
        blockMeta.val.refCount += 1.Natural
        trace "Updated refCount for",
          cid = blockMeta.val.cid, refCount = blockMeta.val.refCount
        record = blockMeta.toRaw

      # update records
      records[record.key] = record

    trace "Records to put ", records = records.len
    success toSeq(records.values)

  trace "Put or update leaf and block metadata", treeCid, count = updates.len
  if err =? (
    await self.metaDs.tryPutAtomic(updates, maxRetries = 3, putLeafAndBlockMetaAtomic)
  ).errorOption:
    trace "Unable to put or update leaf and block metadata", error = err.msg
    return failure(err)

  success()

proc putOrUpdateLeafBlockMeta*(
    self: RepoStore,
    treeCid: Cid,
    index: Natural,
    blkCid: Cid,
    proof: ArchivistProof,
    blockSize = DefaultBlockSize,
): Future[?!void] {.async: (raises: [CancelledError], raw: true).} =
  self.putOrUpdateLeafBlockMeta(treeCid, @[(index, blkCid, proof, blockSize)])

proc delLeafBlockMetadata*(
    self: RepoStore, treeCid: Cid, index: seq[Natural]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Update leaf and block metadata, the delete is two step
  ## to avoid refcount divergence:
  ##
  ## - We first do an atomic update of the block refcount and
  ## set leafs as deleted = true.
  ## - If a crash occurs in between, recounts stay consistent
  ## We then delete leafs and blocks who's refcount is 0.
  ##

  logScope:
    treeCid = treeCid

  trace "Deleting leaf and block metadata"

  let
    # TODO: This is highly ineficient under the current schema, but I
    # want to ge this working first.
    #
    # To optimize this we need to avoid O(N) leaf -> block
    # scans (which endup being O(N^2), since we retrieve the same amount of
    # block metadata), we can do this by packing multiple leafs into a single
    # key (sharding the tree storage essentially), this becomes relevant as well
    # when we flatten the tree
    leafKeys = index.deduplicate().mapIt(?blockProofKey(treeCid, it))
    # Get the leafs
    leafsMeta =
      (?await self.metaDs.get(leafKeys, LeafMetadata)).filterIt(not it.val.deleted)
    updateLeafsRecs = leafsMeta.mapIt(
      it.fromRecord(
        LeafMetadata(blkCid: it.val.blkCid, proof: it.val.proof, deleted: true)
      ).toRaw
    )

    # Get the blocks
    blkKeys = leafsMeta.mapIt(?blockMetaKey(it.val.blkCid))
    blksMeta = ?await self.metaDs.get(blkKeys, BlockMetadata)
    updateBlksRecs = blksMeta.mapIt(
      it.fromRecord(
        BlockMetadata(
          refCount: max(0, it.val.refCount - 1), cid: it.val.cid, size: it.val.size
        )
      ).toRaw
    )

  proc atomicUpdateDelMeta(
      records: seq[RawKVRecord], conflicts: seq[Key]
  ): Future[?!seq[RawKVRecord]] {.async: (raises: [CancelledError]), gcsafe.} =
    var records = records.mapIt((it.key, it)).toTable

    let refreshed = ?await self.metaDs.get(conflicts)

    trace "Got refreshed metadata", count = refreshed.len
    for rec in refreshed:
      var record = rec
      trace "Processing record", key = record.key
      if BlockProofKey.ancestor(record.key):
        var leaf = ?toRecord[LeafMetadata](record)
        leaf.val.deleted = true # mark for delete
        trace "Setting leaf to deleted", key = record.key
        record = leaf.toRaw
      elif BlocksMetaKey.ancestor(record.key):
        var blkMeta = ?toRecord[BlockMetadata](record)
        trace "Before decrease refCount", refCount = blkMeta.val.refCount
        blkMeta.val.refCount = max(0, blkMeta.val.refCount - 1)
        trace "Decreassed refCount for block",
          key = record.key, refCount = blkMeta.val.refCount
        record = blkMeta.toRaw
      else:
        return failure(
          "Got an unknown key updating leaf and block metadata - key: " & $record.key
        )

      # update records
      records[record.key] = record

    trace "Refreshed leaf and block records", count = refreshed.len
    success toSeq(records.values)

  ?await self.metaDs.tryPutAtomic(
    updateLeafsRecs & updateBlksRecs, maxRetries = 3, atomicUpdateDelMeta
  )

  # if no retry, we need to get the records first
  let
    toDeleteLeafMeta =
      ?await self.metaDs.get(updateLeafsRecs.mapIt(it.key), LeafMetadata)
    toDeleteBlockMeta = (
      ?await self.metaDs.get(updateBlksRecs.mapIt(it.key), BlockMetadata)
    ).filterIt(it.val.refCount == 0)

  trace "Got leaf and block metadata",
    leafMeta = toDeleteLeafMeta.len, blockMeta = toDeleteBlockMeta.len

  if toDeleteBlockMeta.len > 0:
    let
      skippedFs =
        (?await self.delFromBlocksStore(toDeleteBlockMeta.mapIt(it.val.cid))).toHashSet

      skippedRecs =
        ?await self.deleteBlocksMetaRecs(
          toDeleteBlockMeta.filterIt(it.val.cid notin skippedFs)
        )

    if skippedRecs.len > 0:
      trace "Some blocks were not deleted", skipped = skippedRecs.len

  if toDeleteLeafMeta.len > 0:
    let failedDeletes =
      # NOTE: actual deletes are optimistic, they will be picked up
      # by the maintenance - blocks with refCount = 0 and leafs with
      # delete = true are going to be dropped
      ?await self.metaDs.delete(toDeleteLeafMeta)

    if failedDeletes.len > 0:
      trace "Some records failed to delete", failedDeletes = failedDeletes.len

  success()

proc delLeafBlockMetadata*(
    self: RepoStore, treeCid: Cid, index: Natural
): Future[?!void] {.async: (raises: [CancelledError], raw: true).} =
  self.delLeafBlockMetadata(treeCid, @[index])

proc getLeafMetadata*(
    self: RepoStore, treeCid: Cid, index: Natural
): Future[?!LeafMetadata] {.async: (raises: [CancelledError]).} =
  let key = ?blockProofKey(treeCid, index)

  without leafMd =? await self.metaDs.get(key, LeafMetadata), err:
    if err of KVStoreKeyNotFound:
      return failure(newException(BlockNotFoundError, err.msg))
    else:
      return failure(err)

  success(leafMd.val)
