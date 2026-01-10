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
import pkg/libp2p/multicodec
import pkg/metrics
import pkg/questionable
import pkg/questionable/results

import ./coders
import ./types
import ../blockstore
import ../../keys
import ../../blocktype
import ../../logutils
import ../../merkletree
import ../../utils/digest

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
  records.mapIt((it.key, it)).toTable

proc updateMetrics*(self: RepoStore) =
  ## Update prometheus metrics from in-memory cache
  archivist_repostore_blocks.set(self.totalBlocks.int64)
  archivist_repostore_bytes_used.set(self.quotaUsage.used.int64)
  archivist_repostore_bytes_reserved.set(self.quotaUsage.reserved.int64)

type CounterMiddleware* = proc(failed: seq[RawRecord]): Future[?!seq[RawRecord]] {.
  async: (raises: [CancelledError])
.}

proc refreshQuotaRecord(
    self: RepoStore, key: Key, usedDelta: int64, reservedDelta: int64 = 0
): Future[?!RawRecord] {.async: (raises: [CancelledError]).} =
  ## Refresh quota record with new token and apply deltas
  let (fresh, token) =
    ?await getWithDefault[QuotaUsage](
      self.metaStore, key, QuotaUsage(used: 0.NBytes, reserved: 0.NBytes)
    )
  let updated = QuotaUsage(
    used: max(0'i64, fresh.used.int64 + usedDelta).NBytes,
    reserved: max(0'i64, fresh.reserved.int64 + reservedDelta).NBytes,
  )
  ?validateQuotaLimit(updated, self.quotaMaxBytes)
  success(RawRecord.init(key, encode(updated), token))

proc refreshTotalBlocksRecord(
    self: RepoStore, key: Key, totalDelta: int
): Future[?!RawRecord] {.async: (raises: [CancelledError]).} =
  ## Refresh total blocks record with new token and apply delta
  let (fresh, token) = ?await getWithDefault[Natural](self.metaStore, key, 0.Natural)
  let updatedTotal = max(0, fresh.int + totalDelta).Natural
  success(RawRecord.init(key, encode(updatedTotal), token))

proc makeCounterMiddleware*(
    self: RepoStore, quotaDeltaBytes: int64, totalDelta: int
): CounterMiddleware =
  ## Factory for CAS middleware that handles counter updates on conflict.
  ## Handles QuotaUsedKey and TotalBlocksKey, passes through other records unchanged.
  proc middleware(
      failed: seq[RawRecord]
  ): Future[?!seq[RawRecord]] {.async: (raises: [CancelledError]).} =
    var refreshed: seq[RawRecord]
    for r in failed:
      if r.key == QuotaUsedKey:
        refreshed.add(?await self.refreshQuotaRecord(r.key, quotaDeltaBytes))
      elif r.key == TotalBlocksKey:
        refreshed.add(?await self.refreshTotalBlocksRecord(r.key, totalDelta))
      else:
        refreshed.add(r) # Idempotent records - retry with same data
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
    ?await getWithDefault[Natural](self.metaStore, TotalBlocksKey, 0.Natural)

  # Validate reserved delta - cannot go negative
  let newReservedRaw = currentQuota.reserved.int64 + delta.quotaReservedDelta
  if newReservedRaw < 0:
    raise newException(
      RangeDefect,
      "Cannot release more bytes than reserved: current=" & $currentQuota.reserved &
        ", delta=" & $delta.quotaReservedDelta,
    )

  # Calculate new values (used and total can be clamped safely)
  let newQuota = QuotaUsage(
    used: max(0'i64, currentQuota.used.int64 + delta.quotaUsedDelta).NBytes,
    reserved: newReservedRaw.NBytes,
  )
  let newTotal = max(0, currentTotal.int + delta.totalBlocksDelta).Natural

  ?validateQuotaLimit(newQuota, self.quotaMaxBytes)

  # Build records for atomic batch
  let records =
    @[
      RawRecord.init(QuotaUsedKey, encode(newQuota), quotaToken),
      RawRecord.init(TotalBlocksKey, encode(newTotal), totalToken),
    ]

  # CAS middleware using extracted helpers
  proc middleware(
      failed: seq[RawRecord]
  ): Future[?!seq[RawRecord]] {.async: (raises: [CancelledError]).} =
    var refreshed: seq[RawRecord]
    for r in failed:
      if r.key == QuotaUsedKey:
        refreshed.add(
          ?await self.refreshQuotaRecord(
            r.key, delta.quotaUsedDelta, delta.quotaReservedDelta
          )
        )
      elif r.key == TotalBlocksKey:
        refreshed.add(
          ?await self.refreshTotalBlocksRecord(r.key, delta.totalBlocksDelta)
        )
    success(refreshed)

  let failedRecords = ?await self.metaStore.tryPut(records, middleware = middleware)
  if failedRecords.len > 0:
    return failure("Failed to update counters atomically")

  # Update in-memory cache
  self.quotaUsage = newQuota
  self.totalBlocks = newTotal
  self.updateMetrics()

  success()

###########################################################
# Leaf CID Operations (raw CID bytes storage)
###########################################################

proc putLeafCid*(
    self: RepoStore, treeCid: Cid, index: Natural, blkCid: Cid
): Future[?!StoreResultKind] {.async: (raises: [CancelledError]).} =
  ## Store leaf index -> block CID mapping as raw bytes.
  without key =? datasetLeafKey(treeCid, index), err:
    return failure(err)

  # Check if already exists
  if record =? await get[seq[byte]](self.metaStore, key):
    return success(AlreadyInStore)

  # Store raw CID bytes
  ?await self.metaStore.put(key, blkCid.data.buffer)
  success(Stored)

proc delLeafCid*(
    self: RepoStore, treeCid: Cid, index: Natural
): Future[?!void] {.async: (raises: [CancelledError]).} =
  without key =? datasetLeafKey(treeCid, index), err:
    return failure(err)

  without record =? await get[seq[byte]](self.metaStore, key):
    return success() # Already deleted

  ?await self.metaStore.delete(record)
  success()

proc getLeafCid*(
    self: RepoStore, treeCid: Cid, index: Natural
): Future[?!Cid] {.async: (raises: [CancelledError]).} =
  ## Get block CID for leaf index.
  without key =? datasetLeafKey(treeCid, index), err:
    return failure(err)

  without record =? await get[seq[byte]](self.metaStore, key), err:
    if err of KVStoreKeyNotFound:
      return failure(newException(BlockNotFoundError, err.msg))
    else:
      return failure(err)

  without cid =? Cid.init(record.val).mapFailure, err:
    return failure(err)

  success(cid)

proc putLeafCidsBatch*(
    self: RepoStore, treeCid: Cid, items: seq[(Natural, Cid)]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Batch store leaf CID mappings as raw bytes.
  if items.len == 0:
    return success()

  var records: seq[RawRecord]
  for (index, blkCid) in items:
    without key =? datasetLeafKey(treeCid, index), err:
      return failure(err)
    records.add(RawRecord.init(key, blkCid.data.buffer, 0))

  let failed = ?await self.metaStore.put(records)
  if failed.len > 0:
    return failure("Failed to store leaf CID mappings")

  success()

###########################################################
# Tree Storage Operations
###########################################################

proc putTreeMetadata*(
    self: RepoStore, treeCid: Cid, nleaves: Natural, mcodec: MultiCodec
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Store tree metadata (idempotent - same tree always has same metadata).
  ## Used for reconstructing proofs and validating tree structure.
  without metaKey =? treeMetadataKey(treeCid), err:
    return failure(err)

  # Check if already exists (idempotent)
  if record =? await get[TreeMetadata](self.metaStore, metaKey):
    let existing = record.val
    if existing.nleaves != nleaves or existing.mcodec != mcodec:
      return failure(
        "Tree metadata mismatch: existing nleaves=" & $existing.nleaves & ", mcodec=" &
          $existing.mcodec & "; new nleaves=" & $nleaves & ", mcodec=" & $mcodec
      )
    return success() # Already stored with matching values

  let meta = TreeMetadata(nleaves: nleaves, mcodec: mcodec)
  ?await self.metaStore.put(metaKey, encode(meta))
  success()

proc getTreeMetadata*(
    self: RepoStore, treeCid: Cid
): Future[?!TreeMetadata] {.async: (raises: [CancelledError]).} =
  ## Get tree metadata for proof computation.
  without metaKey =? treeMetadataKey(treeCid), err:
    return failure(err)
  without record =? await get[TreeMetadata](self.metaStore, metaKey), err:
    return failure(err)
  success(record.val)

proc putTreeNode*(
    self: RepoStore, treeCid: Cid, nodeIndex: Natural, hash: ByteHash
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Store a single tree node (idempotent).
  ## Nodes are indexed in flat array order: [leaves..., level1..., level2..., root]
  without nodeKey =? treeNodeKey(treeCid, nodeIndex), err:
    return failure(err)

  # Idempotent - just overwrite (same hash for same position)
  ?await self.metaStore.put(nodeKey, hash)
  success()

proc putTreeNodesBatch*(
    self: RepoStore, treeCid: Cid, nodes: seq[(Natural, ByteHash)]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Batch store tree nodes (idempotent).
  if nodes.len == 0:
    return success()

  var records: seq[RawRecord]
  for (nodeIndex, hash) in nodes:
    without nodeKey =? treeNodeKey(treeCid, nodeIndex), err:
      return failure(err)
    records.add(RawRecord.init(nodeKey, hash, 0))

  let failed = ?await self.metaStore.put(records)
  if failed.len > 0:
    return failure("Failed to store tree nodes")
  success()

proc getTreeNode*(
    self: RepoStore, treeCid: Cid, nodeIndex: Natural
): Future[?!ByteHash] {.async: (raises: [CancelledError]).} =
  ## Get a single tree node.
  without nodeKey =? treeNodeKey(treeCid, nodeIndex), err:
    return failure(err)
  without record =? await get[seq[byte]](self.metaStore, nodeKey), err:
    return failure(err)
  success(record.val)

proc putTreeNodes*(
    self: RepoStore,
    treeCid: Cid,
    nodes: seq[ByteHash],
    nleaves: Natural,
    mcodec: MultiCodec = Sha256HashCodec,
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Store tree nodes as flat array + metadata.
  ## Nodes ordered: [leaves..., parents..., root]
  ## Proofs are computed on-demand from stored nodes.

  if nodes.len == 0:
    return failure("Cannot store empty tree nodes")

  # Store metadata first
  ?await self.putTreeMetadata(treeCid, nleaves, mcodec)

  # Store nodes in batch using indexed pairs
  var nodePairs: seq[(Natural, ByteHash)]
  for i, node in nodes:
    nodePairs.add((i.Natural, node))
  ?await self.putTreeNodesBatch(treeCid, nodePairs)
  success()

proc getTreeNodes*(
    self: RepoStore, treeCid: Cid
): Future[?!(seq[ByteHash], TreeMetadata)] {.async: (raises: [CancelledError]).} =
  ## Retrieve all tree nodes + metadata.
  ## Returns nodes as flat array in layer order.

  # Get metadata first
  without metaKey =? treeMetadataKey(treeCid), err:
    return failure(err)
  without metaRec =? await get[TreeMetadata](self.metaStore, metaKey), err:
    return failure(err)
  let meta = metaRec.val

  # Calculate total nodes: sum of layer sizes
  var totalNodes = 0
  var layerSize = meta.nleaves
  while layerSize > 0:
    totalNodes += layerSize
    if layerSize == 1:
      break
    layerSize = (layerSize + 1) div 2 # divUp

  # Batch get all nodes
  var keys: seq[Key]
  for i in 0 ..< totalNodes:
    without nodeKey =? treeNodeKey(treeCid, i.Natural), err:
      return failure(err)
    keys.add(nodeKey)

  let records = ?await rawkvstore.get(self.metaStore, keys)
  if records.len != totalNodes:
    return
      failure("Missing tree nodes: expected " & $totalNodes & ", got " & $records.len)

  # Build key to record lookup for ordering
  let keyLookup = buildKeyLookup(records)

  # Extract nodes in correct order
  var nodes: seq[ByteHash]
  for i in 0 ..< totalNodes:
    without nodeKey =? treeNodeKey(treeCid, i.Natural), err:
      return failure(err)
    if not keyLookup.hasKey(nodeKey):
      return failure("Missing tree node at index " & $i)
    nodes.add(keyLookup.getOrDefault(nodeKey).val)

  success((nodes, meta))

proc computeProof*(
    self: RepoStore, treeCid: Cid, leafIndex: Natural
): Future[?!ArchivistProof] {.async: (raises: [CancelledError]).} =
  ## Compute proof on-demand from stored tree nodes.
  ## Only fetches the sibling nodes needed for the proof path (supports partial trees).

  let meta = ?await self.getTreeMetadata(treeCid)

  if leafIndex >= meta.nleaves:
    return failure(
      "Leaf index " & $leafIndex & " out of bounds (nleaves=" & $meta.nleaves & ")"
    )

  # Calculate depth
  var depth = 0
  var layerSize = meta.nleaves
  while layerSize > 1:
    depth.inc
    layerSize = (layerSize + 1) div 2

  # Get the zero hash for padding odd trees
  without mhash =? meta.mcodec.mhash(), err:
    return failure(err)
  let zero: ByteHash = newSeq[byte](mhash.size)

  # Collect sibling hashes by walking the proof path
  # Flat array layout: [leaves (layer 0), layer 1, layer 2, ..., root]
  var path: seq[ByteHash]
  var k = leafIndex.int # Position within current layer
  var m = meta.nleaves.int # Size of current layer
  var layerOffset = 0 # Flat array offset for current layer

  for i in 0 ..< depth:
    let siblingIdxInLayer = k xor 1 # Sibling position within layer

    if siblingIdxInLayer < m:
      # Sibling exists - fetch it from store
      let flatIdx = (layerOffset + siblingIdxInLayer).Natural
      without siblingHash =? await self.getTreeNode(treeCid, flatIdx), err:
        return failure("Missing tree node at index " & $flatIdx & ": " & err.msg)
      path.add(siblingHash)
    else:
      # Sibling doesn't exist (odd tree) - use zero hash
      path.add(zero)

    # Move to next layer
    layerOffset += m
    k = k shr 1
    m = (m + 1) shr 1

  # Build ArchivistProof using the path
  ArchivistProof.init(
    mcodec = meta.mcodec,
    index = leafIndex.int,
    nleaves = meta.nleaves.int,
    nodes = path,
  )

proc extractTreeNodesFromProof*(
    proof: ArchivistProof, leafIndex: Natural, leafHash: ByteHash
): seq[(Natural, ByteHash)] =
  ## Extract tree node (flatIndex, hash) pairs from a proof.
  ## Includes the leaf hash and all sibling hashes along the path.
  ## Used by putCidAndProof to incrementally build the tree.

  var nodes: seq[(Natural, ByteHash)]

  # Store the leaf hash itself
  nodes.add((leafIndex, leafHash))

  # Extract sibling nodes from proof path
  var k = leafIndex.int # Position within current layer
  var m = proof.nleaves # Size of current layer
  var layerOffset = 0 # Flat array offset for current layer

  for siblingHash in proof.path:
    let siblingIdxInLayer = k xor 1
    if siblingIdxInLayer < m:
      # This sibling exists (not padding) - store it
      let flatIdx = (layerOffset + siblingIdxInLayer).Natural
      nodes.add((flatIdx, siblingHash))

    # Move to next layer
    layerOffset += m
    k = k shr 1
    m = (m + 1) shr 1

  nodes

proc putCidAndProofInternal*(
    self: RepoStore, treeCid: Cid, index: Natural, blkCid: Cid, proof: ArchivistProof
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Store leaf CID mapping and incrementally store tree nodes from proof.
  ## This builds the tree piece-by-piece as proofs are stored.

  # 1. Store leaf CID mapping
  discard ?await self.putLeafCid(treeCid, index, blkCid)

  # 2. Store tree metadata (idempotent - same tree always has same metadata)
  ?await self.putTreeMetadata(treeCid, proof.nleaves.Natural, proof.mcodec)

  # 3. Extract leaf hash from blkCid
  without mhash =? blkCid.mhash.mapFailure, err:
    return failure(err)
  let leafHash = mhash.digestBytes

  # 4. Extract and store tree nodes from proof (leaf + siblings)
  let nodes = extractTreeNodesFromProof(proof, index, leafHash)
  ?await self.putTreeNodesBatch(treeCid, nodes)

  success()

proc putCidsAndProofsInternal*(
    self: RepoStore, treeCid: Cid, items: seq[(Natural, Cid, ArchivistProof)]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Batch store leaf CID mappings and tree nodes from proofs.
  ## Deduplicates tree nodes across multiple proofs (multiproof optimization).

  if items.len == 0:
    return success()

  # 1. Get metadata from first proof (all proofs should have same metadata)
  let firstProof = items[0][2]
  ?await self.putTreeMetadata(treeCid, firstProof.nleaves.Natural, firstProof.mcodec)

  # 2. Batch store leaf CID mappings
  var leafItems: seq[(Natural, Cid)]
  for (index, blkCid, _) in items:
    leafItems.add((index, blkCid))
  ?await self.putLeafCidsBatch(treeCid, leafItems)

  # 3. Extract all tree nodes from proofs, deduplicating by flat index
  var nodeMap: Table[Natural, ByteHash] # flatIndex -> hash (deduplicates)
  for (index, blkCid, proof) in items:
    without mhash =? blkCid.mhash.mapFailure, err:
      return failure(err)
    let leafHash = mhash.digestBytes
    let nodes = extractTreeNodesFromProof(proof, index, leafHash)
    for (flatIdx, hash) in nodes:
      nodeMap[flatIdx] = hash # Overwrites duplicates (same hash for same index)

  # 4. Batch store unique tree nodes
  var nodePairs: seq[(Natural, ByteHash)]
  for flatIdx, hash in nodeMap:
    nodePairs.add((flatIdx, hash))
  ?await self.putTreeNodesBatch(treeCid, nodePairs)

  success()

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
    without key =? blockMetaKey(blk.cid), err:
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
    without key =? blockKey(blk.cid), err:
      return failure(err)
    blockRecords.add(RawRecord.init(key, blk.data, 0))

  let failedBlockKeys = ?await self.blockStore.put(blockRecords)

  # 6. Build atomic metadata batch
  var metaRecords: seq[RawRecord]
  var actualNewBytes: NBytes = 0.NBytes
  var actualNewCount = 0

  for blk in newBlocks:
    without blkKey =? blockKey(blk.cid), err:
      return failure(err)
    if blkKey notin failedBlockKeys:
      without metaKey =? blockMetaKey(blk.cid), err:
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
    ?await getWithDefault[Natural](self.metaStore, TotalBlocksKey, 0.Natural)
  metaRecords.add(
    RawRecord.init(TotalBlocksKey, encode(currentTotal + actualNewCount), totalToken)
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
    without blkKey =? blockKey(blk.cid), err:
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

  # Build keys for non-empty cids
  var keys: seq[Key]
  for cid in cids:
    if not cid.isEmpty:
      without key =? blockKey(cid), err:
        return failure(err)
      keys.add(key)

  # Batch get and build lookup
  let records = ?await rawkvstore.get(self.blockStore, keys)
  let keyToData = records.mapIt((it.key, it.val)).toTable

  # Build blocks in original order
  var blocks: seq[Block]
  for cid in cids:
    if cid.isEmpty:
      without emptyBlk =? cid.emptyBlock, err:
        return failure(err)
      blocks.add(emptyBlk)
    else:
      without key =? blockKey(cid), err:
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
    without key =? blockMetaKey(cid), err:
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

  # Calculate actual bytes released by subtracting failed deletions
  let failedKeys = failedDeletes.mapIt(it.key).toHashSet
  var actualBytesReleased = bytesReleased
  for key in failedKeys:
    if keyToMeta.hasKey(key):
      actualBytesReleased -= keyToMeta.getOrDefault(key).size

  # 6. Atomic update of quota + totalBlocks
  let (currentQuota, quotaToken) =
    ?await getWithDefault[QuotaUsage](
      self.metaStore, QuotaUsedKey, QuotaUsage(used: 0.NBytes, reserved: 0.NBytes)
    )
  let (currentTotal, totalToken) =
    ?await getWithDefault[Natural](self.metaStore, TotalBlocksKey, 0.Natural)

  let newQuota = QuotaUsage(
    used: max(0'i64, currentQuota.used.int64 - actualBytesReleased.int64).NBytes,
    reserved: currentQuota.reserved,
  )
  let newTotal = max(0, currentTotal.int - actualDeleted).Natural

  let updateRecords =
    @[
      RawRecord.init(QuotaUsedKey, encode(newQuota), quotaToken),
      RawRecord.init(TotalBlocksKey, encode(newTotal), totalToken),
    ]

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
    without metaKey =? blockMetaKey(cid), err:
      continue
    if metaKey notin failedKeys:
      without blkKey =? blockKey(cid), err:
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
    if metaKey =? blockMetaKey(cid):
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

  # 1. NORMALIZE: Build keys and delta lookup
  var metaKeys: seq[Key]
  var keyToDelta: Table[Key, int]
  var keyCidPairs: seq[(Key, Cid)]

  for (cid, delta) in updates:
    if cid.isEmpty:
      continue
    without key =? blockMetaKey(cid), err:
      return failure(err)
    metaKeys.add(key)
    keyToDelta[key] = delta
    keyCidPairs.add((key, cid))

  if metaKeys.len == 0:
    return success(newSeq[Cid]())

  # 2. Batch get metadata and build lookup
  let metaRecords = ?await rawkvstore.get(self.metaStore, metaKeys)
  let keyToRecord = buildKeyLookup(metaRecords)

  # 3. Build update records (only for blocks that exist)
  var toUpdate: seq[RawRecord]
  var zeroRefCids: seq[Cid]

  for (key, cid) in keyCidPairs:
    if keyToRecord.hasKey(key):
      let rec = keyToRecord.getOrDefault(key)
      without meta =? BlockMetadata.decode(rec.val), err:
        return failure(err)
      let delta = keyToDelta.getOrDefault(key, 0)
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
      let delta = keyToDelta.getOrDefault(r.key, 0)
      without fresh =? await get[BlockMetadata](self.metaStore, r.key):
        continue
      let newRefCount = max(0, fresh.val.refCount.int + delta).Natural
      let newMeta = BlockMetadata(size: fresh.val.size, refCount: newRefCount)
      refreshed.add(RawRecord.init(r.key, encode(newMeta), fresh.token))
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
  without metaKey =? blockMetaKey(blk.cid), err:
    return failure(err)

  if record =? await get[BlockMetadata](self.metaStore, metaKey):
    let currMd = record.val
    if currMd.size == blk.data.len.NBytes:
      # Block exists - verify data exists (orphan recovery)
      without blkKey =? blockKey(blk.cid), err:
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
  without metaKey =? blockMetaKey(cid), err:
    return failure(err)

  without blkKey =? blockKey(cid), err:
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
