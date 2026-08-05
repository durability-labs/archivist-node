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
import ../../manifest
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

  if proof.index < 0 or proof.index >= proof.nleaves:
    return failure(
      newException(TreeNodeValidationError, "Proof index out of range for nleaves")
    )
  if proof.path.len != (?levels(proof.nleaves)) - 1:
    return failure(
      newException(TreeNodeValidationError, "Proof path length does not match nleaves")
    )

  let digestSize = ?proof.mcodec.digestSize.mapFailure
  var
    hash = ?treeNodeDigest(blkCid, proof.mcodec)
    index = proof.index
    width = proof.nleaves
    bottomFlag = ByteTreeKey.KeyBottomLayer

  for level, siblingHash in proof.path:
    if siblingHash.len != digestSize:
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
        ?compress(siblingHash, hash, bottomFlag)
      elif index == width - 1:
        ?compress(hash, siblingHash, ByteTreeKey(bottomFlag.ord + 2))
      else:
        ?compress(hash, siblingHash, bottomFlag)

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

proc getTreeProofs*(
    self: RepoStore,
    treeCid: Cid,
    indices: seq[Natural],
    nleaves: Natural,
    mcodec: MultiCodec = Sha256HashCodec,
): Future[?!seq[(Natural, ArchivistProof)]] {.async: (raises: [CancelledError]).} =
  for index in indices:
    if index.int >= nleaves.int:
      return failure(
        newException(TreeNodeValidationError, "Tree leaf index is out of bounds")
      )

  let totalLevels = ?levels(nleaves.int)

  var
    leafKeys: seq[Key]
    leafKeySet: HashSet[Key]
    treeKeys: seq[Key]
    treeKeySet: HashSet[Key]

  for index in indices:
    let targetKey = ?blockLeafKey(treeCid, index)
    if targetKey notin leafKeySet:
      leafKeys.add(targetKey)
      leafKeySet.incl(targetKey)

    var
      k = index.int
      width = nleaves.int

    for level in 0 ..< totalLevels - 1:
      let sibling = k xor 1
      if sibling < width:
        if level == 0:
          let siblingKey = ?blockLeafKey(treeCid, sibling.Natural)
          if siblingKey notin leafKeySet:
            leafKeys.add(siblingKey)
            leafKeySet.incl(siblingKey)
        else:
          let siblingKey =
            ?treeNodeKey(treeCid, (?flatIndex(nleaves.int, level, sibling)).Natural)
          if siblingKey notin treeKeySet:
            treeKeys.add(siblingKey)
            treeKeySet.incl(siblingKey)

      k = k shr 1
      width = (width + 1) shr 1

  let rootKey =
    ?treeNodeKey(treeCid, (?flatIndex(nleaves.int, totalLevels - 1, 0)).Natural)
  if rootKey notin treeKeySet:
    treeKeys.add(rootKey)
    treeKeySet.incl(rootKey)

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

  if rootKey notin nodesByKey:
    return failure(newException(TreeNodeNotFoundError, "Key not found: " & $rootKey))
  let
    rootCid = ?catch(nodesByKey[rootKey])
    rootHash = ?treeNodeDigest(rootCid, mcodec)

  ?validateTreeRoot(treeCid, rootCid)

  let zeroHash = newSeq[byte](?mcodec.digestSize.mapFailure)

  var proofs: seq[(Natural, ArchivistProof)]
  for index in indices:
    block buildProof:
      let targetLeafKey = ?blockLeafKey(treeCid, index)

      if targetLeafKey notin leavesByKey:
        break buildProof
      if (?catch(leavesByKey[targetLeafKey])).deleted:
        return failure(newException(BlockNotFoundError, "Leaf has been deleted"))

      var path: seq[ByteHash]
      var
        k = index.int
        width = nleaves.int

      for level in 0 ..< totalLevels - 1:
        let sibling = k xor 1
        if sibling < width:
          if level == 0:
            # The level-0 sibling hash lives only in the sibling's own leaf
            # record, which is not written atomically with this leaf. A
            # missing or deleted sibling means the proof cannot be generated;
            # callers fall back to the stored proof for this index.
            let key = ?blockLeafKey(treeCid, sibling.Natural)
            if key notin leavesByKey:
              break buildProof
            if (?catch(leavesByKey[key])).deleted:
              break buildProof
            path.add(?treeNodeDigest((?catch(leavesByKey[key])).blkCid, mcodec))
          else:
            let key =
              ?treeNodeKey(treeCid, (?flatIndex(nleaves.int, level, sibling)).Natural)
            if key notin nodesByKey:
              return
                failure(newException(TreeNodeNotFoundError, "Key not found: " & $key))
            path.add(?treeNodeDigest(?catch(nodesByKey[key]), mcodec))
        else:
          path.add(zeroHash)

        k = k shr 1
        width = (width + 1) shr 1

      let
        proof = ?ArchivistProof.init(mcodec, index.int, nleaves.int, path)
        leafHash = ?treeNodeDigest((?catch(leavesByKey[targetLeafKey])).blkCid, mcodec)
      if not ?proof.verify(leafHash, rootHash):
        return failure(
          newException(TreeNodeValidationError, "Persisted tree proof is inconsistent")
        )

      proofs.add((index, proof))

  success(proofs)

proc getTreeProof*(
    self: RepoStore,
    treeCid: Cid,
    index, nleaves: Natural,
    mcodec: MultiCodec = Sha256HashCodec,
): Future[?!ArchivistProof] {.async: (raises: [CancelledError]).} =
  let targetLeafKey = ?blockLeafKey(treeCid, index)
  let proofs = ?await self.getTreeProofs(treeCid, @[index], nleaves, mcodec)
  if proofs.len == 0:
    if ?await self.metaDs.has(targetLeafKey):
      return failure(
        newException(
          TreeNodeNotFoundError, "Level-0 sibling missing for " & $targetLeafKey
        )
      )
    return failure(newException(BlockNotFoundError, "Key not found: " & $targetLeafKey))
  success(proofs[0][1])

proc resolveTreeShape*(
    self: RepoStore, treeCid: Cid, requireCompleted = true
): Future[?!Option[(Natural, MultiCodec)]] {.async: (raises: [CancelledError]).} =
  ## Resolve the shape (leaf count and hash codec) of a dataset tree from the
  ## manifest attached to its overlay. Returns none when the tree cannot be
  ## served from flat nodes (no overlay, no manifest, a non-dataset root
  ## such as a slot root, or - when requireCompleted is set - an overlay that
  ## is not Completed); callers then fall back to stored proofs.
  ##
  ## Both positive and negative results are cached: the manifest attachment
  ## is immutable for a live treeCid, and storeManifestBlock invalidates the
  ## entry when a manifest is (re)attached. Entries are only cached when
  ## requireCompleted is set - non-Completed negatives (and the
  ## requireCompleted = false mode, used for write-time shape binding) are
  ## never cached, so the post-finalize transition picks up generated
  ## serving on the next call. putOverlay additionally invalidates the entry
  ## whenever an overlay transitions away from Completed. The entry is only
  ## written while the overlay still exists; a drop racing resolution is
  ## cleaned up by the re-del in dropOverlay and by dropManifest.
  ##
  withValue(self.treeShapeCache, treeCid, cachedShape):
    return success(cachedShape[])

  without overlayRec =? (await self.metaDs.get(?overlayKey(treeCid), OverlayMetadata)),
    err:
    if err of KVStoreKeyNotFound:
      return success(none[(Natural, MultiCodec)]())
    return failure(err)

  if requireCompleted and overlayRec.val.status != Completed:
    # In-flight writes (Storing/Repairing) can hold leaves whose flat nodes
    # have not landed yet (erasure recovery writes nil-proof leaves first).
    # Serve those from stored proofs; resolved again once Completed.
    return success(none[(Natural, MultiCodec)]())

  without manifestCid =? overlayRec.val.manifestCid:
    return success(none[(Natural, MultiCodec)]())

  without blk =? await self.getBlock(manifestCid), err:
    if err of BlockNotFoundError:
      # The overlay references a manifest block that is not on disk yet:
      # storeManifestBlock commits the manifestCid attachment before the
      # manifest bytes land in the block store. Treat it as absent.
      return success(none[(Natural, MultiCodec)]())
    return failure(err)

  without manifest =? Manifest.decode(blk.data), err:
    return failure(err)

  let shape =
    if treeCid == manifest.treeCid:
      (manifest.blocksCount.Natural, manifest.hcodec).some
    else:
      none[(Natural, MultiCodec)]()

  # Do not cache an entry for an overlay that disappeared while we were
  # resolving - a drop that completed in the meantime would otherwise leave
  # a stale entry behind a re-created overlay. Only cache in the
  # requireCompleted mode: non-Completed negatives must not stick around.
  if requireCompleted and ?await self.metaDs.has(?overlayKey(treeCid)):
    self.treeShapeCache[treeCid] = shape

  success(shape)

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
