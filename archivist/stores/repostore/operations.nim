## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2024 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sets
import std/tables

import pkg/chronos
import pkg/kvstore
import pkg/libp2p/cid
import pkg/metrics
import pkg/stew/bitseqs
import pkg/questionable
import pkg/questionable/results

import ./coders
import ./types
import ./overlays/coders
import ../blockstore
import ../keyutils
import ../../blocktype
import ../../clock
import ../../logutils
import ../../merkletree
import ../../utils

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
  ?await self.metaDs.tryPutAtomic(updates, maxRetries = 10, updateCountersMiddleware)

  if quotaDelta != 0:
    self.quotaUsage.used = max(0, self.quotaUsage.used.int + quotaDelta).NBytes
    archivist_repostore_bytes_used.set(self.quotaUsage.used.int64)

  if reservedDelta != 0:
    self.quotaUsage.reserved =
      max(0, self.quotaUsage.reserved.int + reservedDelta).NBytes
    archivist_repostore_bytes_reserved.set(self.quotaUsage.reserved.int64)

  if blocksDelta != 0:
    self.totalBlocks = max(0, self.totalBlocks.int + blocksDelta).Natural
    archivist_repostore_blocks.set(self.totalBlocks.int64)

  success()

proc deleteBlocksMetaRecs*(
    self: RepoStore, blocksMeta: seq[KVRecord[BlockMetadata]]
): Future[?!seq[KVRecord[BlockMetadata]]] {.async: (raises: [CancelledError]).} =
  ## Delete blocks and metadata for refCount == 0
  ##
  ## Return skipped Records or empty seq if none were skipped
  ##

  trace "Deleting blocks metadata", count = blocksMeta.len
  # delete meta keys
  await self.metaDs.tryDelete(
    blocksMeta.filterIt(it.val.refCount == 0), # never delete if refCount != 0
    maxRetries = 10,
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
    self: RepoStore, cids: seq[Cid]
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
    self: RepoStore, cid: Cid
): Future[?!seq[Cid]] {.async: (raises: [CancelledError], raw: true).} =
  self.tryDeleteBlocks(@[cid])

proc putOrUpdateLeafBlockMeta*(
    self: RepoStore, treeCid: Cid, blocks: seq[(Natural, Cid, ArchivistProof)]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Put or update lef and block metadata
  ##

  # Fetch existing overlay to get correct BitSeq length
  # (overlay must exist before putLeafsAndBlocks is called)
  let
    existingOverlayRec = ?await self.metaDs.get(?overlayKey(treeCid), OverlayMetadata)
    existingOverlay = existingOverlayRec.val

  var
    blkToLeafMap: Table[Key, (RawKVRecord, HashSet[RawKVRecord])]
    leafsMap: Table[Key, RawKVRecord]
    blocksBits = BitSeq.init(blocks.mapIt(it[0]).max() + 1)

  for (index, blkCid, proof) in blocks:
    let
      blkKey = ?blockMetaKey(blkCid)
      leafKey = ?blockLeafKey(treeCid, index)

    var
      blkRec =
        KVRecord[BlockMetadata].init(blkKey, BlockMetadata(refCount: 1, cid: blkCid))
      leafRec =
        KVRecord[LeafMetadata].init(leafKey, LeafMetadata(blkCid: blkCid, proof: proof))

    # we only increase refcount for **NEW LEAFS**, if a leaf
    # already exists, we skip the refCount.inc, thus we make
    # a mapping of block rec -> leaf rec to be able to filter
    # out inserts from updates
    blocksBits.setBit(index)
    leafsMap[leafKey] = leafRec.toRaw
    blkToLeafMap.withValue(blkKey, pairs):
      pairs[][1].incl(leafRec.toRaw)
      blkRec.val.refCount = max(1, pairs[][1].len)
      pairs[][0] = blkRec.toRaw
    do:
      blkToLeafMap[blkKey] = (blkRec.toRaw, [leafRec.toRaw].toHashSet)

  var combinedBlocks = existingOverlay.blocks
  combinedBlocks.combineSafe(blocksBits)

  let overlayMeta = existingOverlayRec.fromRecord(
    OverlayMetadata(
      blocks: combinedBlocks, status: Storing, expiry: existingOverlay.expiry
    )
  ).toRaw

  proc putLeafAndBlockMetaAtomic(
      records: seq[RawKVRecord], conflicts: seq[Key]
  ): Future[?!seq[RawKVRecord]] {.async: (raises: [CancelledError]), gcsafe.} =
    # Then, filter to only block meta keys in conflicts
    var records = records.mapIt((it.key, it)).toTable
    let
      refreshed = ?await self.metaDs.get(conflicts)
      conflictSet = conflicts.toHashSet

    trace "Got refreshed leaf and block records",
      refreshed = refreshed.len, conflicts = conflicts.len

    for rec in refreshed:
      var record = rec

      trace "Processing record", key = record.key
      if BlockLeafKey.ancestor(record.key):
        let incomingLeafRec = ?toRecord[LeafMetadata](?catch(leafsMap[record.key]))
        var currentLeafRec = ?toRecord[LeafMetadata](record)

        currentLeafRec.val.deleted = incomingLeafRec.val.deleted
        currentLeafRec.val.blkCid = incomingLeafRec.val.blkCid

        let
          hasCurrentProof =
            (not currentLeafRec.val.proof.isNil) and
            currentLeafRec.val.proof.path.len > 0
          hasIncomingProof =
            (not incomingLeafRec.val.proof.isNil) and
            incomingLeafRec.val.proof.path.len > 0

        if hasIncomingProof or not hasCurrentProof:
          currentLeafRec.val.proof = incomingLeafRec.val.proof

        record = currentLeafRec.toRaw
      elif BlocksMetaKey.ancestor(record.key):
        var blockMeta = ?toRecord[BlockMetadata](record)
        # Count only new leaf references (leaves NOT in conflict set)
        blkToLeafMap.withValue(record.key, pairs):
          let
            (_, leafRecs) = pairs[]

            # get the intersection
            newLeafs = (leafRecs.mapIt(it.key).toHashSet - conflictSet)

          if newLeafs.len > 0:
            blockMeta.val.refCount += newLeafs.len.Natural
            trace "Updated refCount for",
              cid = blockMeta.val.cid,
              refCount = blockMeta.val.refCount,
              newLeafs = newLeafs.len
          else:
            trace "Skipping refCount increment (all leafs already existed)",
              cid = blockMeta.val.cid, refCount = blockMeta.val.refCount

          record = blockMeta.toRaw
      elif ArchivistOverlaysKey.ancestor(record.key):
        var overlayMetaRec = ?toRecord[OverlayMetadata](record)
        overlayMetaRec.val.blocks.combineSafe(blocksBits)
        trace "Updated overlay meta", overlay = overlayMetaRec.val
        record = overlayMetaRec.toRaw

      # update records
      records[record.key] = record

    trace "Records to put ", records = records.len
    success toSeq(records.values)

  let updates =
    @[overlayMeta] & blkToLeafMap.values.toSeq.mapIt(@[it[0]] & toSeq(it[1])).concat
  trace "Put or update leaf and block metadata", treeCid, recordsCount = updates.len
  if err =? (
    await self.metaDs.tryPutAtomic(updates, maxRetries = 10, putLeafAndBlockMetaAtomic)
  ).errorOption:
    trace "Unable to put or update leaf and block metadata", error = err.msg
    return failure(err)

  success()

proc putOrUpdateLeafBlockMeta*(
    self: RepoStore, treeCid: Cid, index: Natural, blkCid: Cid, proof: ArchivistProof
): Future[?!void] {.async: (raises: [CancelledError], raw: true).} =
  self.putOrUpdateLeafBlockMeta(treeCid, @[(index, blkCid, proof)])

proc delLeafBlockMetadata*(
    self: RepoStore, treeCid: Cid, index: seq[Natural]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Update leaf and block metadata, the delete is two step
  ## to avoid refcount divergence:
  ##
  ## - We first do an atomic update of the block refcount and
  ## set leafs as deleted = true.
  ## - If a crash occurs in between, refCounts stay consistent
  ## We then delete leafs and blocks who's refcount is 0.
  ##
  ## Optimized: First checks overlay BitSeq for fast-path rejection.
  ## If none of the indices to delete have bits set, returns early.
  ##
  ## TODO: This is highly inefficient under the current schema.
  ## To optimize this we need to avoid O(N) leaf -> block
  ## scans (which end up being O(N^2), since we retrieve the same amount of
  ## block metadata), we can do this by packing multiple leafs into a single
  ## key (sharding the tree storage essentially), this becomes relevant as well
  ## when we flatten the tree

  logScope:
    treeCid = treeCid

  trace "Deleting leaf and block metadata"

  let
    overlayMeta = ?await self.metaDs.get(?overlayKey(treeCid), OverlayMetadata)
    bits = overlayMeta.val.blocks
    uniqueIdxs = index.deduplicate()

  if not uniqueIdxs.anyIt(it < bits.len and bits[it]):
    trace "No bits set in BitSeq for indices to delete, fast-path return"
    return success()

  # Continue with existing logic
  let
    leafKeys = uniqueIdxs.mapIt(?blockLeafKey(treeCid, it))
    leafsMeta =
      (?await self.metaDs.get(leafKeys, LeafMetadata)).filterIt(not it.val.deleted)
    updateLeafsRecs = leafsMeta.mapIt(
      it.fromRecord(
        LeafMetadata(blkCid: it.val.blkCid, proof: it.val.proof, deleted: true)
      )
    )

  # Build aggregation table: block key -> set of leaf indices
  # This ensures we correctly decrement refCount when multiple leaves
  # reference the same block
  var blkToLeafIndices: Table[Key, HashSet[Natural]]
  for leafMeta in leafsMeta:
    let
      blkKey = ?blockMetaKey(leafMeta.val.blkCid)
      # Extract index from leaf key: /meta/leafs/{treeCid}/{index}
      idx = ?catch(parseInt(leafMeta.key.value))

    blkToLeafIndices.withValue(blkKey, indices):
      indices[].incl(idx.Natural)
    do:
      blkToLeafIndices[blkKey] = [idx.Natural].toHashSet

  # Get unique block keys and build update records with correct refCount decrement
  let
    uniqueBlkKeys = toSeq(blkToLeafIndices.keys)
    blksMeta = ?await self.metaDs.get(uniqueBlkKeys, BlockMetadata)
    updateBlksRecs = blksMeta.mapIt(
      block:
        let leafCount =
          blkToLeafIndices.getOrDefault(it.key, initHashSet[Natural]()).len

        it.fromRecord(
          BlockMetadata(refCount: max(0, it.val.refCount - leafCount), cid: it.val.cid)
        )
    )

  var blockBits = BitSeq.init(uniqueIdxs.max() + 1)
  blockBits.combineSafe(overlayMeta.val.blocks)
  for i in uniqueIdxs:
    blockBits.clearBit(i)

  let updateOverlayRec = overlayMeta.fromRecord(
    OverlayMetadata(blocks: blockBits, status: Deleting, expiry: self.clock.now())
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
      if BlockLeafKey.ancestor(record.key):
        var leaf = ?toRecord[LeafMetadata](record)
        leaf.val.deleted = true # mark for delete
        trace "Setting leaf to deleted", key = record.key
        record = leaf.toRaw
      elif BlocksMetaKey.ancestor(record.key):
        var blkMeta = ?toRecord[BlockMetadata](record)
        # Decrement by the count of leaves pointing to this block
        let leafCount =
          blkToLeafIndices.getOrDefault(record.key, initHashSet[Natural]()).len
        trace "Before decrease refCount",
          refCount = blkMeta.val.refCount, leafCount = leafCount
        blkMeta.val.refCount = max(0, blkMeta.val.refCount - leafCount)
        trace "Decreased refCount for block",
          key = record.key, refCount = blkMeta.val.refCount
        record = blkMeta.toRaw
      elif ArchivistOverlaysKey.ancestor(record.key):
        var overlayMetaRec = ?toRecord[OverlayMetadata](record)
        # Re-apply clearBit operations on fresh overlay data
        # to avoid clobbering concurrent updates
        blockBits.combineSafe(overlayMetaRec.val.blocks)
        for i in uniqueIdxs:
          blockBits.clearBit(i)

        overlayMetaRec.val.blocks = blockBits
        overlayMetaRec.val.status = Deleting
        overlayMetaRec.val.expiry = self.clock.now()
        trace "Updated overlay meta for delete", overlay = overlayMetaRec.val
        record = overlayMetaRec.toRaw
      else:
        return failure(
          "Got an unknown key updating leaf and block metadata - key: " & $record.key
        )

      # update records
      records[record.key] = record

    trace "Refreshed leaf and block records", count = refreshed.len
    success toSeq(records.values)

  ?await self.metaDs.tryPutAtomic(
    @[updateOverlayRec.toRaw] & updateLeafsRecs.mapIt(it.toRaw) &
      updateBlksRecs.mapIt(it.toRaw),
    maxRetries = 10,
    atomicUpdateDelMeta,
  )

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
  let key = ?blockLeafKey(treeCid, index)

  without leafMd =? await self.metaDs.get(key, LeafMetadata), err:
    if err of KVStoreKeyNotFound:
      return failure(newException(BlockNotFoundError, err.msg))
    else:
      return failure(err)

  success(leafMd.val)

proc verifyOverlayBitSeqConsistency*(
    self: RepoStore, treeCid: Cid
): Future[?!seq[(Natural, BitSeqInconsistency)]] {.async: (raises: [CancelledError]).} =
  ## Verify that the overlay BitSeq is consistent with leaf metadata.
  ##
  ## Returns a sequence of (index, reason) for each inconsistency found.
  ## An empty sequence means the overlay is consistent.
  ##
  ## Consistency rules:
  ## - If bit i is set in BitSeq, leaf metadata must exist at index i and not be deleted
  ## - If leaf metadata exists at index i and is not deleted, bit i must be set in BitSeq
  ##
  ## Note: This is an expensive operation that queries all leaf metadata.
  ## Use for debugging and testing only.
  ##

  var inconsistencies: seq[(Natural, BitSeqInconsistency)]

  let
    overlayMeta = ?await self.metaDs.get(?overlayKey(treeCid), OverlayMetadata)
    bits = overlayMeta.val.blocks
    iter =
      ?(await query(self.metaDs, Query.init(?blockLeafQueryKey(treeCid)), LeafMetadata))

  var leafIndices: HashSet[Natural]
  for recordFut in iter:
    if record =? ?catch(?(await recordFut)):
      let indexStr = record.key.value
      without idx =? parseInt(indexStr).catch, err:
        inconsistencies.add((0.Natural, InvalidKeyFormat))
        trace "Invalid leaf metadata key format", key = record.key
        continue
      leafIndices.incl(idx.Natural)

      if record.val.deleted:
        if idx < bits.len and bits[idx]:
          inconsistencies.add((idx.Natural, BitSetButLeafDeleted))
      else:
        if idx >= bits.len or not bits[idx]:
          inconsistencies.add((idx.Natural, LeafExistsButBitNotSet))

  for i in 0 ..< bits.len:
    if bits[i] and i notin leafIndices:
      inconsistencies.add((i.Natural, BitSetButNoLeafMetadata))

  success(inconsistencies)
