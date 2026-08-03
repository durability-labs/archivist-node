{.push raises: [].}

import std/sets
import std/tables
import std/options

import pkg/chronos
import pkg/kvstore
import pkg/libp2p/[cid, multicodec, multihash]
import pkg/questionable
import pkg/questionable/results

import ./types
import ./coders
import ./lifecycle
import ./overlays/coders
import ../blockstore
import ../keyutils
import ../../archivisttypes
import ../../errors
import ../../merkletree
import ../../utils
from ../../utils/digest import digestBytes

logScope:
  topics = "archivist repostore treeops"

func treeNodeCidFromHash(hash: seq[byte], mcodec: MultiCodec): ?!Cid =
  let mhash = ?MultiHash.init(mcodec, hash).mapFailure
  Cid.init(CIDv1, DatasetRootCodec, mhash).mapFailure

func treeNodeDigest(cid: Cid, mcodec: MultiCodec): ?!seq[byte] =
  without mhash =? cid.mhash.mapFailure, err:
    trace "Unable to get mhash", err = err.msg
    return failure(err)

  if mhash.mcodec != mcodec:
    return failure(newException(TreeNodeValidationError, "Tree node codec mismatch"))

  success(mhash.digestBytes)

func validateTreeRoot(treeCid: Cid, rootCid: Cid): ?!void =
  if rootCid != treeCid:
    return
      failure(newException(TreeNodeValidationError, "Tree root does not match treeCid"))

  success()

func addTreeNodeRecord(
    treeCid: Cid,
    flatIdx: Natural,
    cid: Cid,
    records: var seq[RawKVRecord],
    incomingByKey: var Table[Key, Cid],
): ?!void =
  let key = ?treeNodeKey(treeCid, flatIdx)
  if key in incomingByKey:
    if ?catch(incomingByKey[key]) != cid:
      return failure(newException(TreeNodeConflictError, "Tree node already exists"))
    return success()

  records.add(KVRecord[TreeNodeMetadata].init(key, TreeNodeMetadata(cid: cid)).toRaw)
  incomingByKey[key] = cid
  success()

func addProofTreeNodes*(
    treeCid, blkCid: Cid,
    proof: ArchivistProof,
    records: var seq[RawKVRecord],
    incomingByKey: var Table[Key, Cid],
): ?!void =
  if proof.isNil:
    return success()

  let mhash = ?proof.mcodec.mhash()
  var
    hash = ?treeNodeDigest(blkCid, proof.mcodec)
    index = proof.index
    width = proof.nleaves
    bottomFlag = ByteTreeKey.KeyBottomLayer

  for level, siblingHash in proof.path:
    if siblingHash.len != mhash.size:
      return failure(
        newException(TreeNodeValidationError, "Tree node hash length is invalid")
      )

    let sibling = index xor 1
    if level >= 1 and sibling < width:
      ?addTreeNodeRecord(
        treeCid,
        (?flatIndex(proof.nleaves, level, sibling)).Natural,
        ?treeNodeCidFromHash(siblingHash, proof.mcodec),
        records,
        incomingByKey,
      )

    let parentHash =
      if (index mod 2) != 0:
        ?compress(siblingHash, hash, bottomFlag, mhash)
      elif index == width - 1:
        ?compress(hash, siblingHash, ByteTreeKey(bottomFlag.ord + 2), mhash)
      else:
        ?compress(hash, siblingHash, bottomFlag, mhash)

    ?addTreeNodeRecord(
      treeCid,
      (?flatIndex(proof.nleaves, level + 1, index shr 1)).Natural,
      ?treeNodeCidFromHash(parentHash, proof.mcodec),
      records,
      incomingByKey,
    )

    hash = parentHash
    index = index shr 1
    width = (width + 1) shr 1
    bottomFlag = ByteTreeKey.KeyNone

  success()

proc putTreeNodes*(
    self: RepoStore, treeCid: Cid, nodes: seq[(Natural, Cid)]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  var
    treeRecords: seq[RawKVRecord]
    incomingByKey: Table[Key, Cid]

  for (flatIdx, cid) in nodes:
    let key = ?treeNodeKey(treeCid, flatIdx)

    if key in incomingByKey:
      if incomingByKey.getOrDefault(key) != cid:
        return failure(newException(TreeNodeConflictError, "Tree node already exists"))
      continue

    treeRecords.add(
      KVRecord[TreeNodeMetadata].init(key, TreeNodeMetadata(cid: cid)).toRaw
    )
    incomingByKey[key] = cid

  if treeRecords.len == 0:
    return success()

  self.deletingLock.enter(treeCid)
  defer:
    self.deletingLock.leave(treeCid)

  let overlayRec = ?await self.metaDs.get(?overlayKey(treeCid), OverlayMetadata)
  if overlayRejectsWrites(overlayRec.val.status):
    return failure(newException(OverlayDeletingError, "Overlay is not writable"))

  let overlayKey = overlayRec.key
  var records = @[overlayRec.toRaw]
  records.add(treeRecords)

  proc resolveTreeNodeConflicts(
      records: seq[RawKVRecord], conflicts: seq[Key]
  ): Future[?!seq[RawKVRecord]] {.async: (raises: [CancelledError]), gcsafe.} =
    var refreshedByKey: Table[Key, RawKVRecord]
    for record in ?await self.metaDs.get(conflicts):
      if record.key == overlayKey:
        let overlay = ?toRecord[OverlayMetadata](record)
        if overlayRejectsWrites(overlay.val.status):
          return failure(newException(OverlayDeletingError, "Overlay is not writable"))
      elif TreeNodeKey.ancestor(record.key):
        let
          existing = ?toRecord[TreeNodeMetadata](record)
          incomingCid = ?catch(incomingByKey[record.key])
        if existing.val.cid != incomingCid:
          return
            failure(newException(TreeNodeConflictError, "Tree node already exists"))

      refreshedByKey[record.key] = record

    var resolved: seq[RawKVRecord]
    for record in records:
      if record.key in conflicts:
        resolved.add(?catch(refreshedByKey[record.key]))
      else:
        resolved.add(record)

    success(resolved)

  ?await self.metaDs.tryPutAtomic(records, maxRetries = 3, resolveTreeNodeConflicts)
  success()

proc putTreeNode*(
    self: RepoStore, treeCid: Cid, flatIdx: Natural, cid: Cid
): Future[?!void] {.async: (raises: [CancelledError], raw: true).} =
  self.putTreeNodes(treeCid, @[(flatIdx, cid)])

proc getTreeNode*(
    self: RepoStore, treeCid: Cid, flatIdx: Natural
): Future[?!Cid] {.async: (raises: [CancelledError]).} =
  let key = ?treeNodeKey(treeCid, flatIdx)

  without node =? await self.metaDs.get(key, TreeNodeMetadata), err:
    if err of KVStoreKeyNotFound:
      return failure(newException(TreeNodeNotFoundError, err.msg))
    return failure(err)

  success(node.val.cid)

proc getTreeNodes*(
    self: RepoStore, treeCid: Cid, indices: seq[Natural]
): Future[?!seq[(Natural, Cid)]] {.async: (raises: [CancelledError]).} =
  var keys: seq[Key]
  for flatIdx in indices:
    keys.add(?treeNodeKey(treeCid, flatIdx))

  let records = ?await self.metaDs.get(keys, TreeNodeMetadata)

  var nodesByKey: Table[Key, Cid]
  for record in records:
    nodesByKey[record.key] = record.val.cid

  var nodes: seq[(Natural, Cid)]
  for flatIdx in indices:
    let key = ?treeNodeKey(treeCid, flatIdx)
    if key notin nodesByKey:
      return failure(newException(TreeNodeNotFoundError, "Key not found: " & $key))
    nodes.add((flatIdx, ?catch(nodesByKey[key])))

  success(nodes)

proc putTree*(
    self: RepoStore, treeCid: Cid, tree: ArchivistTree
): Future[?!void] {.async: (raises: [CancelledError]).} =
  var nodes: seq[(Natural, Cid)]
  for level in 1 ..< tree.levels:
    for index, hash in tree.layers[level]:
      nodes.add(
        (
          (?flatIndex(tree.leavesCount, level, index)).Natural,
          ?treeNodeCidFromHash(hash, tree.mcodec),
        )
      )

  ?await self.putTreeNodes(treeCid, nodes)
  success()

proc putTree*(
    self: RepoStore, tree: ArchivistTree
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ?await self.putTree(?tree.rootCid, tree)
  success()

proc getTree*(
    self: RepoStore,
    treeCid: Cid,
    nleaves: Natural,
    mcodec: MultiCodec = Sha256HashCodec,
): Future[?!ArchivistTree] {.async: (raises: [CancelledError]).} =
  var leafKeys: seq[Key]
  for index in 0 ..< nleaves.int:
    leafKeys.add(?blockLeafKey(treeCid, index.Natural))

  let leafRecords = ?await self.metaDs.get(leafKeys, LeafMetadata)

  var leavesByKey: Table[Key, LeafMetadata]
  for record in leafRecords:
    leavesByKey[record.key] = record.val

  var leaves: seq[ByteHash]
  for key in leafKeys:
    if key notin leavesByKey:
      return failure(newException(BlockNotFoundError, "Key not found: " & $key))
    if (?catch(leavesByKey[key])).deleted:
      return failure(newException(BlockNotFoundError, "Leaf has been deleted"))
    leaves.add(?treeNodeDigest((?catch(leavesByKey[key])).blkCid, mcodec))

  let tree = ?ArchivistTree.init(mcodec, leaves)
  ?validateTreeRoot(treeCid, ?tree.rootCid)

  var treeKeys: seq[Key]
  var expectedByKey: Table[Key, Cid]
  for level in 1 ..< tree.levels:
    for index, hash in tree.layers[level]:
      let
        flatIdx = (?flatIndex(tree.leavesCount, level, index)).Natural
        key = ?treeNodeKey(treeCid, flatIdx)
        computedCid = ?treeNodeCidFromHash(hash, tree.mcodec)
      treeKeys.add(key)
      expectedByKey[key] = computedCid

  let treeRecords = ?await self.metaDs.get(treeKeys, TreeNodeMetadata)

  var storedByKey: Table[Key, Cid]
  for record in treeRecords:
    storedByKey[record.key] = record.val.cid

  for key, expectedCid in expectedByKey:
    if key notin storedByKey or ?catch(storedByKey[key]) != expectedCid:
      return failure(
        newException(TreeNodeValidationError, "Persisted tree nodes are inconsistent")
      )

  success(tree)

proc getTreeProof*(
    self: RepoStore,
    treeCid: Cid,
    index, nleaves: Natural,
    mcodec: MultiCodec = Sha256HashCodec,
): Future[?!ArchivistProof] {.async: (raises: [CancelledError]).} =
  if index.int >= nleaves.int:
    return
      failure(newException(TreeNodeValidationError, "Tree leaf index is out of bounds"))

  let totalLevels = ?levels(nleaves.int)

  var
    leafKeys: seq[Key]
    treeKeys: seq[Key]
    targetLeafKey = ?blockLeafKey(treeCid, index)

  leafKeys.add(targetLeafKey)

  if totalLevels > 1:
    treeKeys.add(
      ?treeNodeKey(treeCid, (?flatIndex(nleaves.int, totalLevels - 1, 0)).Natural)
    )

  var
    k = index.int
    width = nleaves.int

  for level in 0 ..< totalLevels - 1:
    let sibling = k xor 1
    if sibling < width:
      if level == 0:
        let key = ?blockLeafKey(treeCid, sibling.Natural)
        if key notin leafKeys:
          leafKeys.add(key)
      else:
        let key =
          ?treeNodeKey(treeCid, (?flatIndex(nleaves.int, level, sibling)).Natural)
        if key notin treeKeys:
          treeKeys.add(key)

    k = k shr 1
    width = (width + 1) shr 1

  let
    leafRecords = ?await self.metaDs.get(leafKeys, LeafMetadata)
    treeRecords = ?await self.metaDs.get(treeKeys, TreeNodeMetadata)

  var
    leavesByKey: Table[Key, LeafMetadata]
    nodesByKey: Table[Key, Cid]

  for record in leafRecords:
    leavesByKey[record.key] = record.val

  for record in treeRecords:
    nodesByKey[record.key] = record.val.cid

  var
    rootCid: Cid
    rootHash: seq[byte]

  if totalLevels == 1:
    if targetLeafKey notin leavesByKey:
      return
        failure(newException(BlockNotFoundError, "Key not found: " & $targetLeafKey))
    if (?catch(leavesByKey[targetLeafKey])).deleted:
      return failure(newException(BlockNotFoundError, "Leaf has been deleted"))
    rootCid = (?catch(leavesByKey[targetLeafKey])).blkCid
    rootHash = ?treeNodeDigest(rootCid, mcodec)
  else:
    let rootKey =
      ?treeNodeKey(treeCid, (?flatIndex(nleaves.int, totalLevels - 1, 0)).Natural)
    if rootKey notin nodesByKey:
      return failure(newException(TreeNodeNotFoundError, "Key not found: " & $rootKey))
    rootCid = ?catch(nodesByKey[rootKey])
    rootHash = ?treeNodeDigest(rootCid, mcodec)

  ?validateTreeRoot(treeCid, rootCid)

  var path: seq[ByteHash]
  k = index.int
  width = nleaves.int

  let zeroHash = newSeq[byte]((?mcodec.mhash()).size)
  for level in 0 ..< totalLevels - 1:
    let sibling = k xor 1
    if sibling < width:
      if level == 0:
        let key = ?blockLeafKey(treeCid, sibling.Natural)
        if key notin leavesByKey:
          return failure(newException(BlockNotFoundError, "Key not found: " & $key))
        if (?catch(leavesByKey[key])).deleted:
          return failure(newException(BlockNotFoundError, "Leaf has been deleted"))
        path.add(?treeNodeDigest((?catch(leavesByKey[key])).blkCid, mcodec))
      else:
        let key =
          ?treeNodeKey(treeCid, (?flatIndex(nleaves.int, level, sibling)).Natural)
        if key notin nodesByKey:
          return failure(newException(TreeNodeNotFoundError, "Key not found: " & $key))
        path.add(?treeNodeDigest(?catch(nodesByKey[key]), mcodec))
    else:
      path.add(zeroHash)

    k = k shr 1
    width = (width + 1) shr 1

  if targetLeafKey notin leavesByKey:
    return failure(newException(BlockNotFoundError, "Key not found: " & $targetLeafKey))
  if (?catch(leavesByKey[targetLeafKey])).deleted:
    return failure(newException(BlockNotFoundError, "Leaf has been deleted"))

  let
    proof = ?ArchivistProof.init(mcodec, index.int, nleaves.int, path)
    leafHash = ?treeNodeDigest((?catch(leavesByKey[targetLeafKey])).blkCid, mcodec)
  if not ?proof.verify(leafHash, rootHash):
    return failure(
      newException(TreeNodeValidationError, "Persisted tree proof is inconsistent")
    )

  success(proof)

proc delTreeNodes*(
    self: RepoStore, treeCid: Cid, indices: seq[Natural]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  var keys: seq[Key]
  for flatIdx in indices.deduplicate():
    keys.add(?treeNodeKey(treeCid, flatIdx))

  let records = ?await self.metaDs.get(keys, TreeNodeMetadata)
  if records.len > 0:
    ?await self.metaDs.tryDeleteAtomic(records.toKeyRecord)

  success()

proc delTreeNodes*(
    self: RepoStore, treeCid: Cid
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ?await self.metaDs.dropPrefix(?(TreeNodeKey / $treeCid))
  success()
