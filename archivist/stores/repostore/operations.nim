{.push raises: [].}

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
## The atomic operations preserve consistency even in the event of crashes, however it
## requires care with the order of operations. We should avoid writing blocks to the
## filesystem before writing the metadata, because that would require expensive filesystem
## scans (which we used to do) to find orphaned blocks. If we write the metadata first,
## we can always recover from missing on disk block, by either re-downloading or dropping
## the meta entry.
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

  trace "Deleting blocks", count = cids.len

  let dedupped = cids.deduplicate().filterIt(not it.isEmpty)

  # Check refcounts before deleting from disk - only delete blocks
  # whose refCount is 0 (or that have no metadata at all)
  var
    toDelete: seq[Cid]
    skippedByRefCount: seq[Cid]

  let blocksMeta =
    ?await self.metaDs.get(dedupped.mapIt(?blockMetaKey(it)), BlockMetadata)

  var metaByKey = initTable[Key, KVRecord[BlockMetadata]]()
  for rec in blocksMeta:
    metaByKey[rec.key] = rec

  for cid in dedupped:
    let key = ?blockMetaKey(cid)
    if key in metaByKey:
      let rec = ?catch(metaByKey[key])
      if rec.val.refCount == 0:
        toDelete.add(cid)
      else:
        skippedByRefCount.add(cid)
    else:
      # No metadata - safe to delete
      toDelete.add(cid)

  # Delete fs blocks for refCount == 0 only
  let skippedCids = ?await self.delFromBlocksStore(toDelete)

  # Delete metadata for successfully deleted fs blocks
  let deletedCids = toDelete.toHashSet - skippedCids.toHashSet
  var deletedMetaKeys: HashSet[Key]
  for cid in deletedCids:
    deletedMetaKeys.incl(?blockMetaKey(cid))

  var deletedMeta: seq[KVRecord[BlockMetadata]]
  for rec in blocksMeta:
    if rec.key in deletedMetaKeys:
      deletedMeta.add(rec)

  discard ?await self.deleteBlocksMetaRecs(deletedMeta)

  # Return all skipped cids (refCount > 0 + failed disk deletes)
  success skippedByRefCount & skippedCids

proc tryDeleteBlocks*(
    self: RepoStore, cid: Cid
): Future[?!seq[Cid]] {.async: (raises: [CancelledError], raw: true).} =
  self.tryDeleteBlocks(@[cid])

type BlockLeafTuple =
  tuple[index: Natural, blkCid: Cid, cellCid: ?Cid, proof: ArchivistProof]

proc putLeafBlockMetaImpl(
    self: RepoStore, treeCid: Cid, blocks: seq[BlockLeafTuple]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Core implementation for leaf and block metadata writes.
  ##
  ## When the cellCid is set, we treat the leaf as a cell leaf,
  ## and the index and treeCid corresponds to the cell index and
  ## tree of the slot, when it isn't set, this is a regular block
  ## leaf and it's index is the index of the leaf in a regular top
  ## level tree.
  ##
  ## The main difference apart from representing different types of
  ## objects, is that multiple cells point to the same block,
  ## so they might increment the same block's refCount several times.
  ##
  ## All writes - leaf records, block refcounts, and overlay BitSeq -
  ## happen in a single atomic transaction, so no partial state is ever
  ## visible per batch.
  ##

  # Fetch existing overlay to get correct BitSeq length
  # (overlay must exist before putBlocks is called)
  trace "Fetching existing overlay", treeCid = treeCid, blocksCount = blocks.len

  let
    existingOverlayRec = ?await self.metaDs.get(?overlayKey(treeCid), OverlayMetadata)
    treeCidStr = $treeCid

  var overlayMeta = existingOverlayRec.val
  trace "Got existing overlay", treeCid, existingBitmapLen = overlayMeta.blocks.len

  # abort if overlay is already being deleted
  if overlayMeta.status == Deleting:
    return failure(newException(OverlayDeletingError, "Overlay is being deleted"))

  var
    blkToLeafMap: Table[Key, (RawKVRecord, HashSet[RawKVRecord])]
    leafsMap: Table[Key, RawKVRecord]
    blocksBits = BitSeq.init(blocks.mapIt(it[0]).max() + 1)

  for (index, blkCid, cellCid, proof) in blocks:
    let
      blkKey = ?blockMetaKey(blkCid)
      leafKey = ?blockLeafKey(treeCidStr, index)

    var
      blkRec =
        KVRecord[BlockMetadata].init(blkKey, BlockMetadata(refCount: 1, cid: blkCid))
      leafRec =
        if cCid =? cellCid:
          KVRecord[LeafMetadata].init(
            leafKey,
            LeafMetadata(blkCid: blkCid, proof: proof, isCell: true, cellCid: cCid),
          )
        else:
          KVRecord[LeafMetadata].init(
            leafKey, LeafMetadata(blkCid: blkCid, proof: proof)
          )

    # we only increase refcount for **NEW LEAVES**, if a leaf
    # already exists, we skip the refCount.inc, thus we make
    # a mapping of block rec -> leaf rec to be able to filter
    # out inserts from updates
    blocksBits.setBit(index)
    leafsMap[leafKey] = leafRec.toRaw

    # Skip block metadata for empty blkCid (pad blocks)
    if not blkCid.isEmpty:
      blkToLeafMap.withValue(blkKey, pairs):
        pairs[][1].incl(leafRec.toRaw)
        blkRec.val.refCount = max(1, pairs[][1].len)
        pairs[][0] = blkRec.toRaw
      do:
        blkToLeafMap[blkKey] = (blkRec.toRaw, [leafRec.toRaw].toHashSet)

  overlayMeta.blocks.combineSafe(blocksBits)

  proc putLeafAndBlockMetaAtomic(
      records: seq[RawKVRecord], conflicts: seq[Key]
  ): Future[?!seq[RawKVRecord]] {.async: (raises: [CancelledError]), gcsafe.} =
    var
      records = records.mapIt((it.key, it)).toTable
      refreshed = ?await self.metaDs.get(conflicts)

    let conflictSet = conflicts.toHashSet

    trace "Got refreshed leaf and block records",
      refreshed = refreshed.len, conflicts = conflicts.len

    # Update the overlay first, to avoid writing over a deleted overlays
    for i, rec in refreshed:
      if ArchivistOverlaysKey.ancestor(rec.key):
        let overlayMetaRec = ?toRecord[OverlayMetadata](rec)
        # Abort if overlay is being deleted
        if overlayMetaRec.val.status == Deleting:
          return failure(newException(OverlayDeletingError, "Overlay is being deleted"))

        # Update overlay and mark for removal
        var updatedRec = overlayMetaRec
        updatedRec.val.blocks.combineSafe(overlayMeta.blocks)
        trace "Updated overlay meta", overlay = updatedRec.val
        overlayMeta = updatedRec.val
        records[rec.key] = updatedRec.toRaw
        refreshed.del(i)
        break

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

      # update records
      records[record.key] = record

    trace "Records to put ", records = records.len
    success toSeq(records.values)

  let updates =
    @[existingOverlayRec.fromRecord(overlayMeta).toRaw] &
    blkToLeafMap.values.toSeq.mapIt(it[0]) & leafsMap.values.toSeq

  trace "Put or update leaf and block metadata", treeCid, recordsCount = updates.len
  if err =? (
    await self.metaDs.tryPutAtomic(updates, maxRetries = 10, putLeafAndBlockMetaAtomic)
  ).errorOption:
    trace "Unable to put or update leaf and block metadata", error = err.msg
    return failure(err)

  # cache the final overlay
  self.overlayCache[?overlayKey(treeCid)] = overlayMeta

  success()

proc putLeafBlockMeta*(
    self: RepoStore, treeCid: Cid, blocks: seq[(Natural, Cid, ArchivistProof)]
): Future[?!void] {.async: (raises: [CancelledError], raw: true).} =
  ## Put or update leaf and block metadata (plain blocks).
  ##
  self.putLeafBlockMetaImpl(treeCid, blocks.mapIt((it[0], it[1], Cid.none, it[2])))

proc putLeafBlockMeta*(
    self: RepoStore, treeCid: Cid, index: Natural, blkCid: Cid, proof: ArchivistProof
): Future[?!void] {.async: (raises: [CancelledError], raw: true).} =
  self.putLeafBlockMeta(treeCid, @[(index, blkCid, proof)])

proc putCellLeafBlockMeta*(
    self: RepoStore, treeCid: Cid, blocks: seq[(Natural, Cid, Cid, ArchivistProof)]
): Future[?!void] {.async: (raises: [CancelledError], raw: true).} =
  ## Put or update leaf and block metadata for slot proof cell leaves.
  ##
  ## Each item is (index, blkCid, blkCid, proof):
  ##   - cellCid: the cell digest (stored as LeafMetadata.cellCid)
  ##   - blkCid:  the actual block CID (refcount key, LeafMetadata.blkCid)
  ##
  ## All updates (leaf record with cellCid, block refcount, overlay BitSeq)
  ## are committed in a single atomic transaction.
  ##

  self.putLeafBlockMetaImpl(
    treeCid,
    blocks.mapIt((index: it[0], blkCid: it[2], cellCid: it[1].some, proof: it[3])),
  )

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
    existingOverlayMeta = ?await self.metaDs.get(?overlayKey(treeCid), OverlayMetadata)
    uniqueIdxs = index.deduplicate()

  var overlayMeta = existingOverlayMeta.val
  if not uniqueIdxs.anyIt(it < overlayMeta.blocks.len and overlayMeta.blocks[it]):
    trace "No bits set in BitSeq for indices to delete, fast-path return"
    return success()

  # Continue with existing logic
  let
    treeCidStr = $treeCid
    leafKeys = uniqueIdxs.mapIt(?blockLeafKey(treeCidStr, it))
    leafsMeta =
      (?await self.metaDs.get(leafKeys, LeafMetadata)).filterIt(not it.val.deleted)
    updateLeafsRecs = leafsMeta.mapIt(
      it.fromRecord(
        if it.val.isCell:
          LeafMetadata(
            blkCid: it.val.blkCid,
            proof: it.val.proof,
            deleted: true,
            isCell: true,
            cellCid: it.val.cellCid,
          )
        else:
          LeafMetadata(blkCid: it.val.blkCid, proof: it.val.proof, deleted: true)
      )
    )

  # Build aggregation table block key -> set of leaf indices
  # This ensures we correctly decrement refCount when multiple leaves
  # reference the same block
  # Skip empty blkCid (pad blocks) - no block metadata to decrement
  var blkToLeafIndices: Table[Key, HashSet[Natural]]
  for leafMeta in leafsMeta:
    if not leafMeta.val.blkCid.isEmpty:
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
  blockBits.combineSafe(overlayMeta.blocks)
  for i in uniqueIdxs:
    blockBits.clearBit(i)

  let deleteExpiry = self.clock.now()
  overlayMeta.status = Deleting
  overlayMeta.expiry = deleteExpiry
  overlayMeta.blocks = blockBits

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
        overlayMetaRec.val.blocks.combineSafe(overlayMeta.blocks)
        for i in uniqueIdxs:
          overlayMetaRec.val.blocks.clearBit(i)

        overlayMetaRec.val.status = Deleting
        overlayMetaRec.val.expiry = deleteExpiry

        trace "Updated overlay meta for delete", overlay = overlayMetaRec.val
        overlayMeta = overlayMetaRec.val
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
    @[existingOverlayMeta.fromRecord(overlayMeta).toRaw] &
      updateLeafsRecs.mapIt(it.toRaw) & updateBlksRecs.mapIt(it.toRaw),
    maxRetries = 10,
    atomicUpdateDelMeta,
  )

  # cache the final overlay after delete
  self.overlayCache[?overlayKey(treeCid)] = overlayMeta

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
