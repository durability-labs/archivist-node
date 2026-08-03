import std/strutils
import std/algorithm
import std/sequtils
import std/os
import std/tempfiles

import pkg/questionable
import pkg/questionable/results

import pkg/chronos
import pkg/stew/byteutils
import pkg/stew/bitseqs
import pkg/kvstore
import pkg/taskpools

import pkg/archivist/stores
import pkg/archivist/stores/keyutils
import pkg/archivist/stores/repostore/operations
import pkg/archivist/stores/repostore/types
import pkg/archivist/archivisttypes
import pkg/archivist/blocktype as bt
import pkg/archivist/clock
import pkg/archivist/manifest
import pkg/archivist/merkletree
import pkg/archivist/merkletree/archivist
import pkg/archivist/merkletree/archivist/asynctree
import pkg/archivist/utils
import pkg/archivist/utils/asynciter
import pkg/archivist/utils/iter

import ../../../asynctest
import ../../helpers
import ../../helpers/mockclock
import ../../examples

import ./overlays/helpers

proc testRepoStore*(
    name: string,
    repoDsProvider: KVStoreProvider,
    metaDsProvider: KVStoreProvider,
    before: Before = nil,
    after: After = nil,
) =
  suite name:
    var
      repoDs: KVStore
      metaDs: KVStore
      mockClock: MockClock
      repo: RepoStore

    let now: SecondsSince1970 = 123

    setup:
      if not before.isNil:
        await before()
      repoDs = repoDsProvider()
      metaDs = metaDsProvider()
      mockClock = MockClock.new()
      mockClock.set(now)
      repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 200'nb)
      await repo.start()

    teardown:
      await repo.close()
      (await repoDs.close()).tryGet()
      (await metaDs.close()).tryGet()
      if not after.isNil:
        await after()

    # -------------------------------------------------------
    # Tree node metadata tests
    # -------------------------------------------------------

    template ensureOverlay(treeCid: Cid) =
      (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

    proc testLeaves(values: varargs[byte]): seq[seq[byte]] =
      var leaves: seq[seq[byte]]
      for value in values:
        leaves.add(newSeqWith(32, value))
      leaves

    template storeTreeLeaves(treeCid: Cid, tree: ArchivistTree) =
      var items: seq[(Natural, Cid, ArchivistProof)]
      for i in 0 ..< tree.leavesCount:
        items.add(
          (i.Natural, tree.getLeafCid(i.Natural).tryGet(), tree.getProof(i).tryGet())
        )
      (await repo.putCidsAndProofs(treeCid, items)).tryGet()

    test "Should persist and load Archivist tree nodes":
      let
        leaves = testLeaves(1'u8, 2'u8, 3'u8, 4'u8)
        tree = ArchivistTree.init(Sha256HashCodec, leaves).tryGet()
        treeCid = tree.rootCid.tryGet()

      ensureOverlay(treeCid)
      storeTreeLeaves(treeCid, tree)
      (await repo.putTree(tree)).tryGet()

      let loaded = (await repo.getTree(treeCid, tree.leavesCount.Natural)).tryGet()

      check:
        loaded.root.tryGet() == tree.root.tryGet()
        loaded.leaves == tree.leaves

    test "Should generate proof from persisted tree nodes":
      let
        leaves = testLeaves(1'u8, 2'u8, 3'u8, 4'u8, 5'u8)
        tree = ArchivistTree.init(Sha256HashCodec, leaves).tryGet()
        treeCid = tree.rootCid.tryGet()
        index = 3.Natural

      ensureOverlay(treeCid)
      storeTreeLeaves(treeCid, tree)
      (await repo.putTree(treeCid, tree)).tryGet()

      let
        persistedProof =
          (await repo.getTreeProof(treeCid, index, tree.leavesCount.Natural)).tryGet()
        memoryProof = tree.getProof(index.int).tryGet()

      check:
        persistedProof.path == memoryProof.path
        persistedProof.verify(tree.leaves[index], tree.root.tryGet()).tryGet()

      for i in 0 ..< tree.leavesCount:
        let proof = (
          await repo.getTreeProof(treeCid, i.Natural, tree.leavesCount.Natural)
        ).tryGet()
        check proof.verify(tree.leaves[i], tree.root.tryGet()).tryGet()

    test "Should reject persisted tree reads with mismatched root cid":
      let
        leaves = testLeaves(1'u8, 2'u8, 3'u8)
        tree = ArchivistTree.init(Sha256HashCodec, leaves).tryGet()
        overlayCid = Cid.example

      ensureOverlay(overlayCid)
      storeTreeLeaves(overlayCid, tree)
      (await repo.putTree(overlayCid, tree)).tryGet()

      check:
        (await repo.getTree(overlayCid, tree.leavesCount.Natural)).isErr
        (await repo.getTreeProof(overlayCid, 0.Natural, tree.leavesCount.Natural)).isErr

    test "Should reject inconsistent persisted tree nodes":
      let
        leaves = testLeaves(1'u8, 2'u8, 3'u8)
        tree = ArchivistTree.init(Sha256HashCodec, leaves).tryGet()
        treeCid = tree.rootCid.tryGet()
        badNode = createTestBlock(15).cid
        siblingInternalIdx = flatIndex(tree.leavesCount, 1, 1).tryGet().Natural

      ensureOverlay(treeCid)
      storeTreeLeaves(treeCid, tree)
      (await repo.putTree(tree)).tryGet()
      (await repo.delTreeNodes(treeCid, @[siblingInternalIdx])).tryGet()
      (await repo.putTreeNode(treeCid, siblingInternalIdx, badNode)).tryGet()

      check:
        (await repo.getTree(treeCid, tree.leavesCount.Natural)).isErr
        (await repo.getTreeProof(treeCid, 0.Natural, tree.leavesCount.Natural)).isErr

    test "Should generate proof for a single-leaf persisted tree":
      let
        leaves = testLeaves(7'u8)
        tree = ArchivistTree.init(Sha256HashCodec, leaves).tryGet()
        treeCid = tree.rootCid.tryGet()

      ensureOverlay(treeCid)
      storeTreeLeaves(treeCid, tree)
      (await repo.putTree(tree)).tryGet()

      let proof = (await repo.getTreeProof(treeCid, 0.Natural, 1.Natural)).tryGet()
      check proof.verify(tree.leaves[0], tree.root.tryGet()).tryGet()

    test "Should put and get tree nodes":
      let
        treeCid = Cid.example
        hashA = createTestBlock(1).cid
        hashB = createTestBlock(2).cid
        nodes = @[(0.Natural, hashA), (2.Natural, hashB)]

      ensureOverlay(treeCid)
      (await repo.putTreeNodes(treeCid, nodes)).tryGet()

      check:
        (await repo.getTreeNode(treeCid, 0.Natural)).tryGet() == hashA
        (await repo.getTreeNode(treeCid, 2.Natural)).tryGet() == hashB
        (await repo.getTreeNodes(treeCid, @[0.Natural, 2.Natural])).tryGet() == nodes

    test "Should treat identical tree node writes as idempotent":
      let
        treeCid = Cid.example
        hash = createTestBlock(1).cid

      ensureOverlay(treeCid)
      (await repo.putTreeNode(treeCid, 0.Natural, hash)).tryGet()
      (await repo.putTreeNode(treeCid, 0.Natural, hash)).tryGet()

      check (await repo.getTreeNode(treeCid, 0.Natural)).tryGet() == hash

    test "Should keep duplicate tree node batch writes idempotent":
      let
        treeCid = Cid.example
        hash = createTestBlock(1).cid

      ensureOverlay(treeCid)
      (await repo.putTreeNodes(treeCid, @[(0.Natural, hash), (0.Natural, hash)])).tryGet()

      check:
        (await repo.getTreeNode(treeCid, 0.Natural)).tryGet() == hash
        (await repo.getTreeNodes(treeCid, @[0.Natural])).tryGet() == @[
          (0.Natural, hash)
        ]

    test "Should reject duplicate tree node batch writes with conflicting hash":
      let
        treeCid = Cid.example
        hashA = createTestBlock(1).cid
        hashB = createTestBlock(2).cid

      ensureOverlay(treeCid)
      expect TreeNodeConflictError:
        (await repo.putTreeNodes(treeCid, @[(0.Natural, hashA), (0.Natural, hashB)])).tryGet()

      check (await repo.getTreeNode(treeCid, 0.Natural)).isErr

    test "Should reject conflicting tree node writes":
      let
        treeCid = Cid.example
        hashA = createTestBlock(1).cid
        hashB = createTestBlock(2).cid

      ensureOverlay(treeCid)
      (await repo.putTreeNode(treeCid, 0.Natural, hashA)).tryGet()

      expect TreeNodeConflictError:
        (await repo.putTreeNode(treeCid, 0.Natural, hashB)).tryGet()

    test "Should keep batch tree node writes atomic on conflict":
      let
        treeCid = Cid.example
        hashA = createTestBlock(1).cid
        hashB = createTestBlock(2).cid
        hashC = createTestBlock(3).cid

      ensureOverlay(treeCid)
      (await repo.putTreeNode(treeCid, 1.Natural, hashB)).tryGet()

      expect TreeNodeConflictError:
        (await repo.putTreeNodes(treeCid, @[(0.Natural, hashA), (1.Natural, hashC)])).tryGet()

      check:
        (await repo.getTreeNode(treeCid, 0.Natural)).isErr
        (await repo.getTreeNode(treeCid, 1.Natural)).tryGet() == hashB

    test "Should reject tree node writes while overlay is deleting":
      let
        treeCid = Cid.example
        hash = createTestBlock(1).cid

      (await repo.putOverlay(treeCid, status = Deleting.some)).tryGet()

      expect OverlayDeletingError:
        (await repo.putTreeNode(treeCid, 0.Natural, hash)).tryGet()

      check (await repo.getTreeNode(treeCid, 0.Natural)).isErr

    test "Should reject tree node writes while overlay is finalizing":
      let
        treeCid = Cid.example
        hash = createTestBlock(1).cid

      (await repo.putOverlay(treeCid, status = Finalizing.some)).tryGet()

      expect OverlayDeletingError:
        (await repo.putTreeNode(treeCid, 0.Natural, hash)).tryGet()

      check (await repo.getTreeNode(treeCid, 0.Natural)).isErr

    test "Should delete tree nodes by tree cid":
      let
        treeCid = Cid.example
        hashA = createTestBlock(1).cid
        hashB = createTestBlock(2).cid

      ensureOverlay(treeCid)
      (await repo.putTreeNodes(treeCid, @[(0.Natural, hashA), (1.Natural, hashB)])).tryGet()
      (await repo.delTreeNodes(treeCid)).tryGet()

      check:
        (await repo.getTreeNode(treeCid, 0.Natural)).isErr
        (await repo.getTreeNode(treeCid, 1.Natural)).isErr

    test "Should delete tree nodes by duplicate indices once":
      let
        treeCid = Cid.example
        hashA = createTestBlock(1).cid
        hashB = createTestBlock(2).cid

      ensureOverlay(treeCid)
      (await repo.putTreeNodes(treeCid, @[(0.Natural, hashA), (1.Natural, hashB)])).tryGet()
      (await repo.delTreeNodes(treeCid, @[0.Natural, 0.Natural])).tryGet()

      check:
        (await repo.getTreeNode(treeCid, 0.Natural)).isErr
        (await repo.getTreeNode(treeCid, 1.Natural)).tryGet() == hashB

    test "Should move tree nodes when finalizing a tmp overlay":
      let
        realTreeCid = Cid.example
        hash = createTestBlock(1).cid
      var tmpTreeCid: Cid

      let finalized = (
        await repo.withTmpOverlay(
          proc(tmpCid: Cid): Future[?!Cid] {.async: (raises: [CancelledError]).} =
            tmpTreeCid = tmpCid
            if err =? (await repo.putTreeNode(tmpCid, 0.Natural, hash)).errorOption:
              return failure(err)
            success(realTreeCid)
        )
      ).tryGet()

      check:
        finalized == realTreeCid
        (await repo.getTreeNode(realTreeCid, 0.Natural)).tryGet() == hash
        (await repo.getTreeNode(tmpTreeCid, 0.Natural)).isErr

    test "Should reject finalization when destination already exists":
      let
        realTreeCid = Cid.example
        hash = createTestBlock(1).cid
        tmpTreeCid = (await repo.createTmpOverlay()).tryGet()

      (await repo.putOverlay(realTreeCid, status = Completed.some)).tryGet()
      (await repo.putTreeNode(tmpTreeCid, 0.Natural, hash)).tryGet()
      (await repo.putTreeNode(realTreeCid, 0.Natural, hash)).tryGet()

      expect KVConflictError:
        (await repo.finalizeOverlay(tmpTreeCid, realTreeCid)).tryGet()

      check:
        (await repo.getTreeNode(realTreeCid, 0.Natural)).tryGet() == hash
        (await repo.getTreeNode(tmpTreeCid, 0.Natural)).tryGet() == hash

    test "Should preserve tmp tree nodes on conflicting finalization destination":
      let
        realTreeCid = Cid.example
        hashA = createTestBlock(1).cid
        hashB = createTestBlock(2).cid
        tmpTreeCid = (await repo.createTmpOverlay()).tryGet()

      (await repo.putOverlay(realTreeCid, status = Completed.some)).tryGet()
      (await repo.putTreeNode(tmpTreeCid, 0.Natural, hashA)).tryGet()
      (await repo.putTreeNode(realTreeCid, 0.Natural, hashB)).tryGet()

      expect KVConflictError:
        (await repo.finalizeOverlay(tmpTreeCid, realTreeCid)).tryGet()

      check:
        (await repo.getTreeNode(tmpTreeCid, 0.Natural)).tryGet() == hashA
        (await repo.getTreeNode(realTreeCid, 0.Natural)).tryGet() == hashB

    test "Should preserve tmp tree nodes when destination has extra tree nodes":
      let
        realTreeCid = Cid.example
        hashA = createTestBlock(1).cid
        hashB = createTestBlock(2).cid
        tmpTreeCid = (await repo.createTmpOverlay()).tryGet()

      (await repo.putOverlay(realTreeCid, status = Completed.some)).tryGet()
      (await repo.putTreeNode(tmpTreeCid, 0.Natural, hashA)).tryGet()
      (await repo.putTreeNode(realTreeCid, 0.Natural, hashA)).tryGet()
      (await repo.putTreeNode(realTreeCid, 1.Natural, hashB)).tryGet()

      expect KVConflictError:
        (await repo.finalizeOverlay(tmpTreeCid, realTreeCid)).tryGet()

      check:
        (await repo.getTreeNode(tmpTreeCid, 0.Natural)).tryGet() == hashA
        (await repo.getTreeNode(realTreeCid, 1.Natural)).tryGet() == hashB

    test "Should reject finalization when destination has only metadata":
      let
        blk = createTestBlock(16)
        (_, tree) = makeManifestAndTree(@[blk]).tryGet()
        proof = tree.getProof(0).tryGet()
        realTreeCid = Cid.example
        tmpTreeCid = (await repo.createTmpOverlay()).tryGet()

      (await repo.putOverlay(realTreeCid, status = Completed.some)).tryGet()
      (await repo.putCidsAndProofs(tmpTreeCid, @[(0.Natural, blk.cid, proof)])).tryGet()

      expect KVConflictError:
        (await repo.finalizeOverlay(tmpTreeCid, realTreeCid)).tryGet()

      check:
        (await repo.getLeafMetadata(tmpTreeCid, 0.Natural)).isOk
        (await repo.getLeafMetadata(realTreeCid, 0.Natural)).isErr

    test "Should drop tree nodes with the overlay":
      let
        treeCid = Cid.example
        hash = createTestBlock(1).cid

      (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()
      (await repo.putTreeNode(treeCid, 0.Natural, hash)).tryGet()
      (await repo.dropOverlay(treeCid)).tryGet()

      check (await repo.getTreeNode(treeCid, 0.Natural)).isErr

    # -------------------------------------------------------
    # Quota / used-bytes tests
    # -------------------------------------------------------

    test "putBlock raises onBlockStored":
      let newBlock1 = bt.Block.new("1".repeat(100).toBytes()).tryGet()

      var storedCid = Cid.example
      proc onStored(cid: Cid): Future[void] {.async: (raises: []).} =
        storedCid = cid

      repo.onBlockStored = onStored.some()

      discard (await putBlockWithOverlay(repo, newBlock1)).tryGet()

      check storedCid == newBlock1.cid

    test "Should update current used bytes on block put":
      let blk = createTestBlock(200)

      check repo.quotaUsedBytes == 0'nb
      discard (await putBlockWithOverlay(repo, blk)).tryGet

      check:
        repo.quotaUsedBytes == 200'nb

    test "Should update current used bytes on block delete":
      let blk = createTestBlock(100)

      check repo.quotaUsedBytes == 0'nb
      let (treeCid, index) = (await putBlockWithOverlay(repo, blk)).tryGet
      check repo.quotaUsedBytes == 100'nb

      (await repo.delBlock(treeCid, index)).tryGet

      check:
        repo.quotaUsedBytes == 0'nb

    test "Should not update current used bytes if block exist":
      let blk = createTestBlock(100)

      check repo.quotaUsedBytes == 0'nb
      discard (await putBlockWithOverlay(repo, blk)).tryGet
      check repo.quotaUsedBytes == 100'nb

      # put again
      discard (await putBlockWithOverlay(repo, blk)).tryGet
      check repo.quotaUsedBytes == 100'nb

    test "Should fail storing passed the quota":
      let blk = createTestBlock(300)

      check repo.totalUsed == 0'nb
      expect QuotaNotEnoughError:
        discard (await putBlockWithOverlay(repo, blk)).tryGet

    test "Should reserve bytes":
      let blk = createTestBlock(100)

      check repo.totalUsed == 0'nb
      discard (await putBlockWithOverlay(repo, blk)).tryGet
      check repo.totalUsed == 100'nb

      (await repo.reserve(100'nb)).tryGet

      check:
        repo.totalUsed == 200'nb
        repo.quotaUsedBytes == 100'nb
        repo.quotaReservedBytes == 100'nb

    test "Should not reserve bytes over max quota":
      let blk = createTestBlock(100)

      check repo.totalUsed == 0'nb
      discard (await putBlockWithOverlay(repo, blk)).tryGet
      check repo.totalUsed == 100'nb

      expect QuotaNotEnoughError:
        (await repo.reserve(101'nb)).tryGet

      check:
        repo.totalUsed == 100'nb
        repo.quotaUsedBytes == 100'nb
        repo.quotaReservedBytes == 0'nb

    test "Should release bytes":
      discard createTestBlock(100)

      check repo.totalUsed == 0'nb
      (await repo.reserve(100'nb)).tryGet
      check repo.totalUsed == 100'nb

      (await repo.release(100'nb)).tryGet

      check:
        repo.totalUsed == 0'nb
        repo.quotaUsedBytes == 0'nb
        repo.quotaReservedBytes == 0'nb

    test "Should not release bytes less than quota":
      check repo.totalUsed == 0'nb
      (await repo.reserve(100'nb)).tryGet
      check repo.totalUsed == 100'nb

      expect QuotaNotEnoughError:
        (await repo.release(101'nb)).tryGet

      check:
        repo.totalUsed == 100'nb
        repo.quotaUsedBytes == 0'nb
        repo.quotaReservedBytes == 100'nb

    test "Should handle duplicate CIDs in same putBlocks batch correctly":
      let blk = createTestBlock(100)

      let (_, tree) = makeManifestAndTree(@[blk, blk]).tryGet()
      let treeCid = tree.rootCid.tryGet()

      var blocks = BitSeq.init(2)

      (
        await repo.putOverlay(
          treeCid = treeCid, status = Completed.some, blocks = blocks
        )
      ).tryGet()

      let
        initialBytes = repo.quotaUsedBytes
        initialBlocks = repo.totalBlocks

        proof0 = tree.getProof(0).tryGet()
        proof1 = tree.getProof(1).tryGet()

      (
        await repo.putBlocks(
          treeCid, @[(blk, 0.Natural, proof0.some), (blk, 1.Natural, proof1.some)]
        )
      ).tryGet()

      check repo.quotaUsedBytes == initialBytes + 100.NBytes
      check repo.totalBlocks == initialBlocks + 1

      (await repo.delBlock(treeCid, 0)).tryGet()
      check (await repo.getBlock(blk.cid)).isOk

      (await repo.delBlock(treeCid, 1)).tryGet()
      check (await repo.getBlock(blk.cid)).isErr

    # -------------------------------------------------------
    # Empty block tests
    # -------------------------------------------------------

    test "Should put empty blocks":
      let blk = Cid.example.emptyBlock.tryGet()
      check (await putBlockWithOverlay(repo, blk)).isOk

    test "Should get empty blocks":
      let blk = Cid.example.emptyBlock.tryGet()

      let got = await repo.getBlock(blk.cid)
      check got.isOk
      check got.get.cid == blk.cid

    test "Should delete empty blocks":
      let blk = Cid.example.emptyBlock.tryGet()
      check (await repo.delBlock(blk.cid)).isOk

    test "Should have empty block":
      let blk = Cid.example.emptyBlock.tryGet()

      let has = await repo.hasBlock(blk.cid)
      check has.isOk
      check has.get

    test "fail getBlock":
      let newBlock = bt.Block.new("New Kids on the Block".toBytes()).tryGet()
      expect BlockNotFoundError:
        discard (await repo.getBlock(newBlock.cid)).tryGet()

    test "fail hasBlock":
      let newBlock = bt.Block.new("New Kids on the Block".toBytes()).tryGet()
      check:
        not (await repo.hasBlock(newBlock.cid)).tryGet()
        not (await newBlock.cid in repo)

    # -------------------------------------------------------
    # Proof-based put/get/delete tests
    # -------------------------------------------------------

    test "Should put block with proof":
      let
        blk = createTestBlock(50)
        (_, tree) = makeManifestAndTree(@[blk]).tryGet()
        treeCid = tree.rootCid.tryGet()
        proof = tree.getProof(0).tryGet()

      var bits = BitSeq.init(1)
      bits.setBit(0)

      (await repo.putOverlay(treeCid = treeCid, status = Completed.some, blocks = bits)).tryGet()
      (await repo.putBlock(treeCid, blk, 0.Natural, proof.some)).tryGet()

      check (await repo.hasBlock(blk.cid)).tryGet()

    test "Should get block with proof":
      let
        blk = createTestBlock(50)
        (_, tree) = makeManifestAndTree(@[blk]).tryGet()
        treeCid = tree.rootCid.tryGet()
        proof = tree.getProof(0).tryGet()

      var bits = BitSeq.init(1)
      bits.setBit(0)

      (await repo.putOverlay(treeCid = treeCid, status = Completed.some, blocks = bits)).tryGet()
      (await repo.putBlock(treeCid, blk, 0.Natural, proof.some)).tryGet()

      let got = (await repo.getBlockAndProof(treeCid, 0.Natural)).tryGet()
      check got[1].cid == blk.cid
      check $got[2] == $proof.some

    test "Should delete block with proof":
      let
        blk = createTestBlock(50)
        (_, tree) = makeManifestAndTree(@[blk]).tryGet()
        treeCid = tree.rootCid.tryGet()
        proof = tree.getProof(0).tryGet()

      var bits = BitSeq.init(1)
      bits.setBit(0)

      (await repo.putOverlay(treeCid = treeCid, status = Completed.some, blocks = bits)).tryGet()
      (await repo.putBlock(treeCid, blk, 0.Natural, proof.some)).tryGet()
      check (await repo.hasBlock(blk.cid)).tryGet()

      (await repo.delBlock(treeCid, 0.Natural)).tryGet()
      check not (await repo.hasBlock(blk.cid)).tryGet()

    test "Should get blocks with proofs":
      let
        dataset = (await makeRandomBlocks(datasetSize = 768, blockSize = 256'nb)).tryGet
        (_, tree) = makeManifestAndTree(dataset).tryGet()
        treeCid = tree.rootCid.tryGet()

      # Use a large enough quota
      let bigRepo =
        RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 5000'nb)

      var bits = BitSeq.init(3)
      bits.setBit(0)
      bits.setBit(1)
      bits.setBit(2)

      (
        await bigRepo.putOverlay(
          treeCid = treeCid, status = Completed.some, blocks = bits
        )
      ).tryGet()

      let
        proof0 = tree.getProof(0).tryGet()
        proof1 = tree.getProof(1).tryGet()
        proof2 = tree.getProof(2).tryGet()

      (
        await bigRepo.putBlocks(
          treeCid,
          @[
            (dataset[0], 0.Natural, proof0.some),
            (dataset[1], 1.Natural, proof1.some),
            (dataset[2], 2.Natural, proof2.some),
          ],
        )
      ).tryGet()

      let unsorted = (
        await bigRepo.getBlocksAndProofs(treeCid, @[0.Natural, 1.Natural, 2.Natural])
      ).tryGet()
      let results = unsorted.sortedByIt(it[0])

      check results.len == 3
      check results[0][1].cid == dataset[0].cid
      check $results[0][2] == $proof0.some
      check results[1][1].cid == dataset[1].cid
      check $results[1][2] == $proof1.some
      check results[2][1].cid == dataset[2].cid
      check $results[2][2] == $proof2.some

    # -------------------------------------------------------
    # Flat-tree serving tests
    # -------------------------------------------------------

    template storeTreeLeaves(
        repo: RepoStore, treeCid: Cid, tree: ArchivistTree, blocks: seq[bt.Block]
    ) =
      var items: seq[(bt.Block, Natural, ArchivistProof)]
      for i in 0 ..< tree.leavesCount:
        items.add((blocks[i], i.Natural, tree.getProof(i).tryGet()))
      (await repo.putBlocks(treeCid, items)).tryGet()

    proc toAsyncIter(cids: seq[Cid]): AsyncIter[Cid] =
      proc lift(cid: Cid): Future[Cid] {.async.} =
        cid

      mapAsync[Cid, Cid](Iter[Cid].new(cids), lift)

    test "Should serve generated proofs from flat nodes":
      let
        dataset = (await makeRandomBlocks(datasetSize = 768, blockSize = 256'nb)).tryGet
        (manifest, tree) = makeManifestAndTree(dataset).tryGet()
        treeCid = tree.rootCid.tryGet()
        bigRepo =
          RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 5000'nb)

      ensureOverlay(treeCid)
      discard (await bigRepo.storeManifest(manifest)).tryGet()
      storeTreeLeaves(bigRepo, treeCid, tree, dataset)

      let
        indices = (0 ..< tree.leavesCount).toSeq.mapIt(it.Natural)
        unsorted = (await bigRepo.getBlocksAndProofs(treeCid, indices)).tryGet()
        results = unsorted.sortedByIt(it[0])

      check results.len == tree.leavesCount
      for i in 0 ..< tree.leavesCount:
        let
          proof = results[i][2]
          memoryProof = tree.getProof(i).tryGet()
        check results[i][0] == i.Natural
        check proof.index == memoryProof.index
        check proof.nleaves == memoryProof.nleaves
        check proof.path == memoryProof.path
        check proof.verify(tree.leaves[i], tree.root.tryGet()).tryGet()

    test "Should fail serving when flat tree nodes are missing":
      let
        dataset = (await makeRandomBlocks(datasetSize = 768, blockSize = 256'nb)).tryGet
        (manifest, tree) = makeManifestAndTree(dataset).tryGet()
        treeCid = tree.rootCid.tryGet()
        bigRepo =
          RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 5000'nb)

      ensureOverlay(treeCid)
      discard (await bigRepo.storeManifest(manifest)).tryGet()
      storeTreeLeaves(bigRepo, treeCid, tree, dataset)
      (await bigRepo.delTreeNodes(treeCid)).tryGet()

      let got = await bigRepo.getBlocksAndProofs(treeCid, @[0.Natural])
      check got.isErr
      check got.error of TreeNodeNotFoundError

    test "Should serve stored proofs when manifest is missing":
      let
        dataset = (await makeRandomBlocks(datasetSize = 768, blockSize = 256'nb)).tryGet
        (_, tree) = makeManifestAndTree(dataset).tryGet()
        treeCid = tree.rootCid.tryGet()
        bigRepo =
          RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 5000'nb)

      ensureOverlay(treeCid)
      storeTreeLeaves(bigRepo, treeCid, tree, dataset)
      (await bigRepo.delTreeNodes(treeCid)).tryGet()

      let
        unsorted = (
          await bigRepo.getBlocksAndProofs(treeCid, @[0.Natural, 1.Natural, 2.Natural])
        ).tryGet()
        results = unsorted.sortedByIt(it[0])

      check results.len == 3
      for i in 0 ..< tree.leavesCount:
        let
          proof = results[i][2]
          storedProof = tree.getProof(i).tryGet()
        check proof.index == storedProof.index
        check proof.nleaves == storedProof.nleaves
        check proof.path == storedProof.path

    test "Should serve stored proofs when treeCid is not the manifest dataset tree":
      let
        dataset = (await makeRandomBlocks(datasetSize = 768, blockSize = 256'nb)).tryGet
        (_, tree) = makeManifestAndTree(dataset).tryGet()
        treeCid = tree.rootCid.tryGet()
        otherDataset =
          (await makeRandomBlocks(datasetSize = 512, blockSize = 256'nb)).tryGet
        (otherManifest, _) = makeManifestAndTree(otherDataset).tryGet()
        bigRepo =
          RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 5000'nb)

      ensureOverlay(treeCid)
      discard (await bigRepo.storeManifestBlock(@[treeCid], otherManifest)).tryGet()
      storeTreeLeaves(bigRepo, treeCid, tree, dataset)
      (await bigRepo.delTreeNodes(treeCid)).tryGet()

      let
        unsorted = (
          await bigRepo.getBlocksAndProofs(treeCid, @[0.Natural, 1.Natural, 2.Natural])
        ).tryGet()
        results = unsorted.sortedByIt(it[0])

      check results.len == 3
      for i in 0 ..< tree.leavesCount:
        let proof = results[i][2]
        check proof.path == tree.getProof(i).tryGet().path

    test "Should serve padding leaves from stored proof":
      let
        dataset =
          (await makeRandomBlocks(datasetSize = 1280, blockSize = 256'nb)).tryGet
        emptyLeafCid = emptyCid(CIDv1, Sha256HashCodec, bt.BlockCodec).tryGet()
        cids = dataset.mapIt(it.cid) & @[emptyLeafCid]
        tree = ArchivistTree.init(cids).tryGet()
        treeCid = tree.rootCid.tryGet()
        manifest =
          Manifest.new(treeCid = treeCid, blockSize = 256'nb, datasetSize = 1536'nb)
        bigRepo =
          RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 5000'nb)

      check tree.leavesCount == 6

      ensureOverlay(treeCid)
      discard (await bigRepo.storeManifest(manifest)).tryGet()

      var items: seq[(bt.Block, Natural, ArchivistProof)]
      for i in 0 ..< 5:
        items.add((dataset[i], i.Natural, tree.getProof(i).tryGet()))
      items.add(
        (bt.emptyBlock(emptyLeafCid).tryGet(), 5.Natural, tree.getProof(5).tryGet())
      )
      (await bigRepo.putBlocks(treeCid, items)).tryGet()

      let
        unsorted = (
          await bigRepo.getBlocksAndProofs(
            treeCid, (0 ..< tree.leavesCount).toSeq.mapIt(it.Natural)
          )
        ).tryGet()
        results = unsorted.sortedByIt(it[0])

      check results.len == 6
      for i in 0 ..< 5:
        check results[i][1].cid == dataset[i].cid
        check results[i][2].path == tree.getProof(i).tryGet().path
        check results[i][2].verify(tree.leaves[i], tree.root.tryGet()).tryGet()
      check results[5][1].cid == emptyLeafCid
      check results[5][2].path == tree.getProof(5).tryGet().path

    test "Should serve proofs for async-built trees":
      let
        dataset = (await makeRandomBlocks(datasetSize = 768, blockSize = 256'nb)).tryGet
        (manifest, tree) = makeManifestAndTree(dataset).tryGet()
        treeCid = tree.rootCid.tryGet()
        bigRepo =
          RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 5000'nb)
      var tp = Taskpool.new(numThreads = 4)

      defer:
        tp.shutdown()

      let asyncTree = (
        await ArchivistTree.buildAsync(toAsyncIter(dataset.mapIt(it.cid)), tp)
      ).tryGet()

      check asyncTree.leavesCount == tree.leavesCount
      check asyncTree.root.tryGet() == tree.root.tryGet()

      ensureOverlay(treeCid)
      discard (await bigRepo.storeManifest(manifest)).tryGet()
      storeTreeLeaves(bigRepo, treeCid, asyncTree, dataset)

      let
        unsorted = (
          await bigRepo.getBlocksAndProofs(treeCid, @[0.Natural, 1.Natural, 2.Natural])
        ).tryGet()
        results = unsorted.sortedByIt(it[0])

      check results.len == tree.leavesCount
      for i in 0 ..< tree.leavesCount:
        let
          proof = results[i][2]
          memoryProof = asyncTree.getProof(i).tryGet()
        check proof.index == memoryProof.index
        check proof.nleaves == memoryProof.nleaves
        check proof.path == memoryProof.path
        check proof.verify(asyncTree.leaves[i], asyncTree.root.tryGet()).tryGet()

    test "Should serve generated proofs even when stored proofs are corrupted":
      let
        dataset = (await makeRandomBlocks(datasetSize = 768, blockSize = 256'nb)).tryGet
        (manifest, tree) = makeManifestAndTree(dataset).tryGet()
        treeCid = tree.rootCid.tryGet()
        bigRepo =
          RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 5000'nb)

      ensureOverlay(treeCid)
      discard (await bigRepo.storeManifest(manifest)).tryGet()
      storeTreeLeaves(bigRepo, treeCid, tree, dataset)

      # Corrupt the persisted proofs: serving must still return proofs that
      # verify, generated from the flat tree nodes.
      for i in 0 ..< tree.leavesCount:
        let key = blockLeafKey(treeCid, i.Natural).tryGet()
        var corrupted = (await bigRepo.metaDs.get(key, LeafMetadata)).tryGet()
        corrupted.val.proof = nil
        (await bigRepo.metaDs.put(corrupted)).tryGet()

      let
        unsorted = (
          await bigRepo.getBlocksAndProofs(treeCid, @[0.Natural, 1.Natural, 2.Natural])
        ).tryGet()
        results = unsorted.sortedByIt(it[0])

      check results.len == 3
      for i in 0 ..< tree.leavesCount:
        let proof = results[i][2]
        check proof.path == tree.getProof(i).tryGet().path
        check proof.verify(tree.leaves[i], tree.root.tryGet()).tryGet()

    test "Should fall back to stored proof when sibling leaf is missing":
      let
        dataset =
          (await makeRandomBlocks(datasetSize = 1024, blockSize = 256'nb)).tryGet
        (manifest, tree) = makeManifestAndTree(dataset).tryGet()
        treeCid = tree.rootCid.tryGet()
        bigRepo =
          RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 5000'nb)

      check tree.leavesCount == 4

      ensureOverlay(treeCid)
      discard (await bigRepo.storeManifest(manifest)).tryGet()

      # Store only leaves 0 and 2 - their siblings (1 and 3) are absent.

      (
        await bigRepo.putBlocks(
          treeCid,
          @[
            (dataset[0], 0.Natural, tree.getProof(0).tryGet()),
            (dataset[2], 2.Natural, tree.getProof(2).tryGet()),
          ],
        )
      ).tryGet()

      let
        unsorted = (
          await bigRepo.getBlocksAndProofs(treeCid, @[0.Natural, 1.Natural, 2.Natural])
        ).tryGet()
        results = unsorted.sortedByIt(it[0])

      check results.len == 2
      check results[0][0] == 0.Natural
      check results[0][2].path == tree.getProof(0).tryGet().path
      check results[0][2].verify(tree.leaves[0], tree.root.tryGet()).tryGet()
      check results[1][0] == 2.Natural
      check results[1][2].path == tree.getProof(2).tryGet().path
      check results[1][2].verify(tree.leaves[2], tree.root.tryGet()).tryGet()

    test "Should forget tree shape when overlay is dropped":
      let
        dataset = (await makeRandomBlocks(datasetSize = 768, blockSize = 256'nb)).tryGet
        (manifest, tree) = makeManifestAndTree(dataset).tryGet()
        treeCid = tree.rootCid.tryGet()
        bigRepo =
          RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 5000'nb)

      ensureOverlay(treeCid)
      discard (await bigRepo.storeManifest(manifest)).tryGet()
      storeTreeLeaves(bigRepo, treeCid, tree, dataset)

      let served = (await bigRepo.getBlocksAndProofs(treeCid, @[0.Natural])).tryGet()
      check served.len == 1
      check treeCid in bigRepo.treeShapeCache

      (await bigRepo.dropOverlay(treeCid)).tryGet()
      check treeCid notin bigRepo.treeShapeCache

    test "Should handle non-existent block with proof":
      let
        blk = createTestBlock(50)
        (_, tree) = makeManifestAndTree(@[blk]).tryGet()
        treeCid = tree.rootCid.tryGet()

      # No overlay or block stored - getBlockAndProof should fail
      let got = await repo.getBlockAndProof(treeCid, 0.Natural)
      check got.isErr

    test "Should delete blocks with proofs":
      let
        dataset = (await makeRandomBlocks(datasetSize = 512, blockSize = 256'nb)).tryGet
        (_, tree) = makeManifestAndTree(dataset).tryGet()
        treeCid = tree.rootCid.tryGet()

      let bigRepo =
        RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 5000'nb)

      var bits = BitSeq.init(2)
      bits.setBit(0)
      bits.setBit(1)

      (
        await bigRepo.putOverlay(
          treeCid = treeCid, status = Completed.some, blocks = bits
        )
      ).tryGet()

      let
        proof0 = tree.getProof(0).tryGet()
        proof1 = tree.getProof(1).tryGet()

      (
        await bigRepo.putBlocks(
          treeCid,
          @[(dataset[0], 0.Natural, proof0.some), (dataset[1], 1.Natural, proof1.some)],
        )
      ).tryGet()

      (await bigRepo.delBlocks(treeCid, @[0.Natural, 1.Natural])).tryGet()

      check not (await bigRepo.hasBlock(dataset[0].cid)).tryGet()
      check not (await bigRepo.hasBlock(dataset[1].cid)).tryGet()

    test "Should handle partial failures in delete blocks":
      let
        dataset = (await makeRandomBlocks(datasetSize = 512, blockSize = 256'nb)).tryGet
        (_, tree) = makeManifestAndTree(dataset).tryGet()
        treeCid = tree.rootCid.tryGet()

      let bigRepo =
        RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 5000'nb)

      var bits = BitSeq.init(2)
      bits.setBit(0)
      # index 1 not set - block at index 1 was never stored

      (
        await bigRepo.putOverlay(
          treeCid = treeCid, status = Completed.some, blocks = bits
        )
      ).tryGet()

      let proof0 = tree.getProof(0).tryGet()

      (await bigRepo.putBlocks(treeCid, @[(dataset[0], 0.Natural, proof0.some)])).tryGet()

      # Deleting index 1 (never stored) should still succeed
      (await bigRepo.delBlocks(treeCid, @[0.Natural, 1.Natural])).tryGet()

      check not (await bigRepo.hasBlock(dataset[0].cid)).tryGet()

    # -------------------------------------------------------
    # hasBlocks tests
    # -------------------------------------------------------

    test "Should handle has blocks":
      let
        dataset = (await makeRandomBlocks(datasetSize = 512, blockSize = 256'nb)).tryGet
        (_, tree) = makeManifestAndTree(dataset).tryGet()
        treeCid = tree.rootCid.tryGet()

      let bigRepo =
        RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 5000'nb)

      var bits = BitSeq.init(2)
      bits.setBit(0)

      (
        await bigRepo.putOverlay(
          treeCid = treeCid, status = Completed.some, blocks = bits
        )
      ).tryGet()

      let proof0 = tree.getProof(0).tryGet()

      (await bigRepo.putBlocks(treeCid, @[(dataset[0], 0.Natural, proof0.some)])).tryGet()

      let unsorted =
        (await bigRepo.hasBlocks(treeCid, @[0.Natural, 1.Natural])).tryGet()
      let results = unsorted.sortedByIt(it[0])

      check results.len == 2
      check results[0][0] == 0.Natural
      check results[0][1] == true
      check results[1][0] == 1.Natural
      check results[1][1] == false

    # -------------------------------------------------------
    # Batch put tests
    # -------------------------------------------------------

    test "Should handle batch put blocks":
      let
        dataset = (await makeRandomBlocks(datasetSize = 768, blockSize = 256'nb)).tryGet
        (_, tree) = makeManifestAndTree(dataset).tryGet()
        treeCid = tree.rootCid.tryGet()

      let bigRepo =
        RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 5000'nb)

      var bits = BitSeq.init(3)
      bits.setBit(0)
      bits.setBit(1)
      bits.setBit(2)

      (
        await bigRepo.putOverlay(
          treeCid = treeCid, status = Completed.some, blocks = bits
        )
      ).tryGet()

      let
        proof0 = tree.getProof(0).tryGet()
        proof1 = tree.getProof(1).tryGet()
        proof2 = tree.getProof(2).tryGet()

      (
        await bigRepo.putBlocks(
          treeCid,
          @[
            (dataset[0], 0.Natural, proof0.some),
            (dataset[1], 1.Natural, proof1.some),
            (dataset[2], 2.Natural, proof2.some),
          ],
        )
      ).tryGet()

      check (await bigRepo.hasBlock(dataset[0].cid)).tryGet()
      check (await bigRepo.hasBlock(dataset[1].cid)).tryGet()
      check (await bigRepo.hasBlock(dataset[2].cid)).tryGet()

    test "Should handle batch get blocks":
      let
        dataset = (await makeRandomBlocks(datasetSize = 768, blockSize = 256'nb)).tryGet
        (_, tree) = makeManifestAndTree(dataset).tryGet()
        treeCid = tree.rootCid.tryGet()

      let bigRepo =
        RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 5000'nb)

      var bits = BitSeq.init(3)
      bits.setBit(0)
      bits.setBit(1)
      bits.setBit(2)

      (
        await bigRepo.putOverlay(
          treeCid = treeCid, status = Completed.some, blocks = bits
        )
      ).tryGet()

      let
        proof0 = tree.getProof(0).tryGet()
        proof1 = tree.getProof(1).tryGet()
        proof2 = tree.getProof(2).tryGet()

      (
        await bigRepo.putBlocks(
          treeCid,
          @[
            (dataset[0], 0.Natural, proof0.some),
            (dataset[1], 1.Natural, proof1.some),
            (dataset[2], 2.Natural, proof2.some),
          ],
        )
      ).tryGet()

      let unsorted =
        (await bigRepo.getBlocks(treeCid, @[0.Natural, 1.Natural, 2.Natural])).tryGet()
      let results = unsorted.sortedByIt(it[0])

      check results.len == 3
      check results[0][1].cid == dataset[0].cid
      check results[1][1].cid == dataset[1].cid
      check results[2][1].cid == dataset[2].cid

    test "Should handle concurrent batch operations":
      let
        dataset = (await makeRandomBlocks(datasetSize = 768, blockSize = 256'nb)).tryGet
        (_, tree) = makeManifestAndTree(dataset).tryGet()
        treeCid = tree.rootCid.tryGet()

      let bigRepo =
        RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 5000'nb)

      var bits = BitSeq.init(3)
      bits.setBit(0)
      bits.setBit(1)
      bits.setBit(2)

      (
        await bigRepo.putOverlay(
          treeCid = treeCid, status = Completed.some, blocks = bits
        )
      ).tryGet()

      let
        proof0 = tree.getProof(0).tryGet()
        proof1 = tree.getProof(1).tryGet()
        proof2 = tree.getProof(2).tryGet()

      # Store blocks concurrently
      let putFuts = await allFinished(
        @[
          bigRepo.putBlock(treeCid, dataset[0], 0.Natural, proof0.some),
          bigRepo.putBlock(treeCid, dataset[1], 1.Natural, proof1.some),
          bigRepo.putBlock(treeCid, dataset[2], 2.Natural, proof2.some),
        ]
      )

      for f in putFuts:
        check not f.failed
        check f.read.isOk

      # Get blocks concurrently
      let getFuts = await allFinished(
        @[
          bigRepo.getBlock(treeCid, 0.Natural),
          bigRepo.getBlock(treeCid, 1.Natural),
          bigRepo.getBlock(treeCid, 2.Natural),
        ]
      )

      for f in getFuts:
        check not f.failed
        check f.read.isOk

    test "Should handle empty batch operations":
      let
        dataset = (await makeRandomBlocks(datasetSize = 256, blockSize = 256'nb)).tryGet
        (_, tree) = makeManifestAndTree(dataset).tryGet()
        treeCid = tree.rootCid.tryGet()

      let bigRepo =
        RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 5000'nb)

      var bits = BitSeq.init(1)
      bits.setBit(0)

      (
        await bigRepo.putOverlay(
          treeCid = treeCid, status = Completed.some, blocks = bits
        )
      ).tryGet()

      # Empty putBlocks
      (await bigRepo.putBlocks(treeCid, newSeq[(bt.Block, Natural, ?ArchivistProof)]())).tryGet()

      # Empty getBlocks
      let emptyGet = (await bigRepo.getBlocks(treeCid, newSeq[Natural]())).tryGet()
      check emptyGet.len == 0

      # Empty delBlocks
      (await bigRepo.delBlocks(treeCid, newSeq[Natural]())).tryGet()

      # Empty hasBlocks
      let emptyHas = (await bigRepo.hasBlocks(treeCid, newSeq[Natural]())).tryGet()
      check emptyHas.len == 0

    test "Should handle single item batch":
      let
        blk = createTestBlock(50)
        (_, tree) = makeManifestAndTree(@[blk]).tryGet()
        treeCid = tree.rootCid.tryGet()
        proof = tree.getProof(0).tryGet()

      var bits = BitSeq.init(1)
      bits.setBit(0)

      (await repo.putOverlay(treeCid = treeCid, status = Completed.some, blocks = bits)).tryGet()
      (await repo.putBlocks(treeCid, @[(blk, 0.Natural, proof.some)])).tryGet()

      let got = (await repo.getBlocks(treeCid, @[0.Natural])).tryGet()
      check got.len == 1
      check got[0][1].cid == blk.cid

    test "Should handle batch with duplicate CIDs":
      let
        blk = createTestBlock(50)
        (_, tree) = makeManifestAndTree(@[blk, blk]).tryGet()
        treeCid = tree.rootCid.tryGet()
        proof0 = tree.getProof(0).tryGet()
        proof1 = tree.getProof(1).tryGet()

      var bits = BitSeq.init(2)
      bits.setBit(0)
      bits.setBit(1)

      (await repo.putOverlay(treeCid = treeCid, status = Completed.some, blocks = bits)).tryGet()

      (
        await repo.putBlocks(
          treeCid, @[(blk, 0.Natural, proof0.some), (blk, 1.Natural, proof1.some)]
        )
      ).tryGet()

      # Block stored once despite appearing at two indices
      check (await repo.hasBlock(blk.cid)).tryGet()
      check repo.totalBlocks == 1

    test "Should handle batch with missing blocks":
      let
        blk = createTestBlock(50)
        (_, tree) = makeManifestAndTree(@[blk]).tryGet()
        treeCid = tree.rootCid.tryGet()
        proof = tree.getProof(0).tryGet()

      var bits = BitSeq.init(1)
      bits.setBit(0)

      (await repo.putOverlay(treeCid = treeCid, status = Completed.some, blocks = bits)).tryGet()
      (await repo.putBlocks(treeCid, @[(blk, 0.Natural, proof.some)])).tryGet()

      # Request index 0 (exists) and index 5 (missing)
      let results = (await repo.getBlocks(treeCid, @[0.Natural, 5.Natural])).tryGet()

      # Only index 0 should be returned
      check results.len == 1
      check results[0][0] == 0.Natural

    # -------------------------------------------------------
    # Batch delete tests
    # -------------------------------------------------------

    test "Should handle batch delete with missing blocks":
      let
        dataset = (await makeRandomBlocks(datasetSize = 256, blockSize = 256'nb)).tryGet
        (_, tree) = makeManifestAndTree(dataset).tryGet()
        treeCid = tree.rootCid.tryGet()

      let bigRepo =
        RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 5000'nb)

      var bits = BitSeq.init(1)
      bits.setBit(0)

      (
        await bigRepo.putOverlay(
          treeCid = treeCid, status = Completed.some, blocks = bits
        )
      ).tryGet()

      let proof = tree.getProof(0).tryGet()
      (await bigRepo.putBlocks(treeCid, @[(dataset[0], 0.Natural, proof.some)])).tryGet()

      # Delete index 0 (exists) and index 5 (does not exist)
      (await bigRepo.delBlocks(treeCid, @[0.Natural, 5.Natural])).tryGet()

      check not (await bigRepo.hasBlock(dataset[0].cid)).tryGet()

    test "Should handle batch delete with partial success":
      let
        dataset = (await makeRandomBlocks(datasetSize = 768, blockSize = 256'nb)).tryGet
        (_, tree) = makeManifestAndTree(dataset).tryGet()
        treeCid = tree.rootCid.tryGet()

      let bigRepo =
        RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 5000'nb)

      var bits = BitSeq.init(3)
      bits.setBit(0)
      bits.setBit(1)
      bits.setBit(2)

      (
        await bigRepo.putOverlay(
          treeCid = treeCid, status = Completed.some, blocks = bits
        )
      ).tryGet()

      let
        proof0 = tree.getProof(0).tryGet()
        proof2 = tree.getProof(2).tryGet()

      # Only store indices 0 and 2; index 1 is not stored

      (
        await bigRepo.putBlocks(
          treeCid,
          @[(dataset[0], 0.Natural, proof0.some), (dataset[2], 2.Natural, proof2.some)],
        )
      ).tryGet()

      # Delete all three - index 1 was never stored but delete should still succeed
      (await bigRepo.delBlocks(treeCid, @[0.Natural, 1.Natural, 2.Natural])).tryGet()

      check not (await bigRepo.hasBlock(dataset[0].cid)).tryGet()
      check not (await bigRepo.hasBlock(dataset[2].cid)).tryGet()

    test "Should handle batch delete with all missing":
      let
        dataset = (await makeRandomBlocks(datasetSize = 256, blockSize = 256'nb)).tryGet
        (_, tree) = makeManifestAndTree(dataset).tryGet()
        treeCid = tree.rootCid.tryGet()

      let bigRepo =
        RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 5000'nb)

      var bits = BitSeq.init(1)
      bits.setBit(0)

      (
        await bigRepo.putOverlay(
          treeCid = treeCid, status = Completed.some, blocks = bits
        )
      ).tryGet()

      # Delete indices that were never stored - should succeed without error
      (await bigRepo.delBlocks(treeCid, @[5.Natural, 10.Natural, 99.Natural])).tryGet()

    test "Should handle batch delete with shared CIDs":
      # Two overlays sharing the same block - deleting from one should not remove the block
      let
        pool = (await makeRandomBlocks(datasetSize = 768, blockSize = 256'nb)).tryGet
        sharedBlk = pool[0]
        unique1 = pool[1]
        unique2 = pool[2]

        (_, tree1) = makeManifestAndTree(@[sharedBlk, unique1]).tryGet()
        treeCid1 = tree1.rootCid.tryGet()
        (_, tree2) = makeManifestAndTree(@[sharedBlk, unique2]).tryGet()
        treeCid2 = tree2.rootCid.tryGet()

      let bigRepo =
        RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 5000'nb)

      var bits1 = BitSeq.init(2)
      bits1.setBit(0)
      var bits2 = BitSeq.init(2)
      bits2.setBit(0)

      (
        await bigRepo.putOverlay(
          treeCid = treeCid1, status = Completed.some, blocks = bits1
        )
      ).tryGet()

      (
        await bigRepo.putOverlay(
          treeCid = treeCid2, status = Completed.some, blocks = bits2
        )
      ).tryGet()

      let
        proof1 = tree1.getProof(0).tryGet()
        proof2 = tree2.getProof(0).tryGet()

      (await bigRepo.putBlocks(treeCid1, @[(sharedBlk, 0.Natural, proof1.some)])).tryGet()
      (await bigRepo.putBlocks(treeCid2, @[(sharedBlk, 0.Natural, proof2.some)])).tryGet()

      check (await bigRepo.blockRefCount(sharedBlk.cid)).tryGet() == 2.Natural

      # Delete from tree1 only - block should remain (refCount 2 -> 1)
      (await bigRepo.delBlocks(treeCid1, @[0.Natural])).tryGet()
      check (await bigRepo.hasBlock(sharedBlk.cid)).tryGet()
      check (await bigRepo.blockRefCount(sharedBlk.cid)).tryGet() == 1.Natural

    test "Should handle batch delete with shared CIDs partial":
      let
        dataset = (await makeRandomBlocks(datasetSize = 512, blockSize = 256'nb)).tryGet
        sharedBlk = dataset[0]
        uniqueBlk = dataset[1]

        (_, tree) = makeManifestAndTree(@[sharedBlk, uniqueBlk]).tryGet()
        treeCid1 = tree.rootCid.tryGet()

        (_, tree2) = makeManifestAndTree(@[sharedBlk]).tryGet()
        treeCid2 = tree2.rootCid.tryGet()

      let bigRepo =
        RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 5000'nb)

      var bits1 = BitSeq.init(2)
      bits1.setBit(0)
      bits1.setBit(1)

      var bits2 = BitSeq.init(1)
      bits2.setBit(0)

      (
        await bigRepo.putOverlay(
          treeCid = treeCid1, status = Completed.some, blocks = bits1
        )
      ).tryGet()

      (
        await bigRepo.putOverlay(
          treeCid = treeCid2, status = Completed.some, blocks = bits2
        )
      ).tryGet()

      let
        tproof0 = tree.getProof(0).tryGet()
        tproof1 = tree.getProof(1).tryGet()
        t2proof0 = tree2.getProof(0).tryGet()

      (
        await bigRepo.putBlocks(
          treeCid1,
          @[(sharedBlk, 0.Natural, tproof0.some), (uniqueBlk, 1.Natural, tproof1.some)],
        )
      ).tryGet()

      (await bigRepo.putBlocks(treeCid2, @[(sharedBlk, 0.Natural, t2proof0.some)])).tryGet()

      # sharedBlk has refCount 2, uniqueBlk has refCount 1
      check (await bigRepo.blockRefCount(sharedBlk.cid)).tryGet() == 2.Natural
      check (await bigRepo.blockRefCount(uniqueBlk.cid)).tryGet() == 1.Natural

      # Delete all blocks from treeCid1
      (await bigRepo.delBlocks(treeCid1, @[0.Natural, 1.Natural])).tryGet()

      # uniqueBlk should be gone, sharedBlk should remain (still in treeCid2)
      check not (await bigRepo.hasBlock(uniqueBlk.cid)).tryGet()
      check (await bigRepo.hasBlock(sharedBlk.cid)).tryGet()

    test "Should handle batch delete with shared CIDs all shared":
      let
        pool = (await makeRandomBlocks(datasetSize = 768, blockSize = 256'nb)).tryGet
        sharedBlk = pool[0]
        unique1 = pool[1]
        unique2 = pool[2]

        (_, tree1) = makeManifestAndTree(@[sharedBlk, unique1]).tryGet()
        treeCid1 = tree1.rootCid.tryGet()
        (_, tree2) = makeManifestAndTree(@[sharedBlk, unique2]).tryGet()
        treeCid2 = tree2.rootCid.tryGet()

      let bigRepo =
        RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 5000'nb)

      var bits1 = BitSeq.init(2)
      bits1.setBit(0)
      var bits2 = BitSeq.init(2)
      bits2.setBit(0)

      (
        await bigRepo.putOverlay(
          treeCid = treeCid1, status = Completed.some, blocks = bits1
        )
      ).tryGet()

      (
        await bigRepo.putOverlay(
          treeCid = treeCid2, status = Completed.some, blocks = bits2
        )
      ).tryGet()

      let
        proof1 = tree1.getProof(0).tryGet()
        proof2 = tree2.getProof(0).tryGet()

      (await bigRepo.putBlocks(treeCid1, @[(sharedBlk, 0.Natural, proof1.some)])).tryGet()
      (await bigRepo.putBlocks(treeCid2, @[(sharedBlk, 0.Natural, proof2.some)])).tryGet()

      check (await bigRepo.blockRefCount(sharedBlk.cid)).tryGet() == 2.Natural

      # Delete from both trees - block should be removed after second delete
      (await bigRepo.delBlocks(treeCid1, @[0.Natural])).tryGet()
      check (await bigRepo.hasBlock(sharedBlk.cid)).tryGet()

      (await bigRepo.delBlocks(treeCid2, @[0.Natural])).tryGet()
      check not (await bigRepo.hasBlock(sharedBlk.cid)).tryGet()

    test "Should not allow non-orphan blocks to be deleted directly":
      let
        innerRepo =
          RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 1000'nb)
        dataset = (await makeRandomBlocks(datasetSize = 512, blockSize = 256'nb)).tryGet
        blk = dataset[0]
        (_, tree) = makeManifestAndTree(dataset).tryGet()
        treeCid = tree.rootCid.tryGet()
        proof = tree.getProof(0).tryGet()

      var blocks = BitSeq.init(1)
      blocks.setBit(0)

      (
        await innerRepo.putOverlay(
          treeCid = treeCid, status = Completed.some, blocks = blocks
        )
      ).tryGet
      (await innerRepo.putBlock(treeCid, blk, 0, proof.some)).tryGet
      let err = (await innerRepo.delBlock(blk.cid)).error()
      check err.msg ==
        "Directly deleting a block that is part of a dataset is not allowed."

    test "Should allow non-orphan blocks to be deleted by dataset reference":
      let
        innerRepo =
          RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 1000'nb)
        dataset = (await makeRandomBlocks(datasetSize = 512, blockSize = 256'nb)).tryGet
        blk = dataset[0]
        (_, tree) = makeManifestAndTree(dataset).tryGet()
        treeCid = tree.rootCid.tryGet()
        proof = tree.getProof(0).tryGet()

      var blocks = BitSeq.init(1)
      blocks.setBit(0)

      (
        await innerRepo.putOverlay(
          treeCid = treeCid, status = Completed.some, blocks = blocks
        )
      ).tryGet
      (await innerRepo.putBlock(treeCid, blk, 0, proof.some)).tryGet

      (await innerRepo.delBlock(treeCid, 0.Natural)).tryGet()
      check not (await blk.cid in innerRepo)

    test "Should not delete a non-orphan block until it is deleted from all parent datasets":
      let
        innerRepo =
          RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 1024'nb)
        blockPool =
          (await makeRandomBlocks(datasetSize = 768, blockSize = 256'nb)).tryGet

        dataset1 = @[blockPool[0], blockPool[1]]
        dataset2 = @[blockPool[1], blockPool[2]]
        sharedBlock = blockPool[1]

        (_, tree1) = makeManifestAndTree(dataset1).tryGet()
        treeCid1 = tree1.rootCid.tryGet()
        (_, tree2) = makeManifestAndTree(dataset2).tryGet()
        treeCid2 = tree2.rootCid.tryGet()

      # Create overlay for tree1
      var blocks1 = BitSeq.init(2)
      blocks1.setBit(0)
      blocks1.setBit(1)

      (
        await innerRepo.putOverlay(
          treeCid = treeCid1, status = Completed.some, blocks = blocks1
        )
      ).tryGet()

      # Put dataset1
      let
        proof1_0 = tree1.getProof(0).tryGet()
        proof1_1 = tree1.getProof(1).tryGet()

      (
        await innerRepo.putBlocks(
          treeCid1,
          @[
            (blockPool[0], 0.Natural, proof1_0.some),
            (sharedBlock, 1.Natural, proof1_1.some),
          ],
        )
      ).tryGet()

      # Shared block should exist with refCount = 1
      check (await innerRepo.blockRefCount(sharedBlock.cid)).tryGet() == 1.Natural

      # Create overlay for tree2
      var blocks2 = BitSeq.init(2)
      blocks2.setBit(0)
      blocks2.setBit(1)

      (
        await innerRepo.putOverlay(
          treeCid = treeCid2, status = Completed.some, blocks = blocks2
        )
      ).tryGet()

      # Put dataset2
      let
        proof2_0 = tree2.getProof(0).tryGet()
        proof2_1 = tree2.getProof(1).tryGet()

      (
        await innerRepo.putBlocks(
          treeCid2,
          @[
            (sharedBlock, 0.Natural, proof2_0.some),
            (blockPool[2], 1.Natural, proof2_1.some),
          ],
        )
      ).tryGet()

      # Shared block should now have refCount = 2
      check (await innerRepo.blockRefCount(sharedBlock.cid)).tryGet() == 2.Natural

      # Delete from tree1
      (await innerRepo.delBlock(treeCid1, 1.Natural)).tryGet()
      check (await innerRepo.blockRefCount(sharedBlock.cid)).tryGet() == 1.Natural
      check (await sharedBlock.cid in innerRepo)

      # Delete from tree2
      (await innerRepo.delBlock(treeCid2, 0.Natural)).tryGet()
      check not (await sharedBlock.cid in innerRepo)

    # -------------------------------------------------------
    # Batch by CID tests (getBlocks by seq[Cid] overload)
    # -------------------------------------------------------

    test "should get multiple blocks by CID":
      let
        cidRepo =
          RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 2000'nb)
        blk1 = createTestBlock(100)
        blk2 = createTestBlock(150)
        blk3 = createTestBlock(200)

      # Store blocks via overlay API
      discard (await putBlockWithOverlay(cidRepo, blk1)).tryGet()
      discard (await putBlockWithOverlay(cidRepo, blk2)).tryGet()
      discard (await putBlockWithOverlay(cidRepo, blk3)).tryGet()

      # Retrieve all three blocks
      let blocks = (await cidRepo.getBlocks(@[blk1.cid, blk2.cid, blk3.cid])).tryGet()
      let returnedCids = blocks.mapIt(it.cid)

      check blocks.len == 3
      check blk1.cid in returnedCids
      check blk2.cid in returnedCids
      check blk3.cid in returnedCids

    test "should return empty seq for empty input":
      let blocks = (await repo.getBlocks(newSeq[Cid]())).tryGet()
      check blocks.len == 0

    test "should skip missing CIDs":
      let
        cidRepo =
          RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 2000'nb)
        blk1 = createTestBlock(100)
        blk2 = createTestBlock(150)

      # Store only 2 blocks
      discard (await putBlockWithOverlay(cidRepo, blk1)).tryGet()
      discard (await putBlockWithOverlay(cidRepo, blk2)).tryGet()

      # Request 3 CIDs (one missing)
      let missingCid = Cid.example
      let blocks = (await cidRepo.getBlocks(@[blk1.cid, missingCid, blk2.cid])).tryGet()

      # Should return only the 2 existing blocks
      check blocks.len == 2

    test "should handle empty CIDs":
      let
        blk1 = createTestBlock(100)
        emptyBlk = Cid.example.emptyBlock.tryGet()

      # Store one real block
      discard (await putBlockWithOverlay(repo, blk1)).tryGet()

      # Request real + empty CID
      let blocks = (await repo.getBlocks(@[blk1.cid, emptyBlk.cid])).tryGet()

      # Should return the real block and synthesized empty block
      check blocks.len == 2

    # -------------------------------------------------------
    # listBlocks tests
    # -------------------------------------------------------

    test "listBlocks Blocks":
      let
        bigRepo =
          RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 5000'nb)
        newBlock1 = bt.Block.new("1".repeat(100).toBytes()).tryGet()
        newBlock2 = bt.Block.new("2".repeat(100).toBytes()).tryGet()
        newBlock3 = bt.Block.new("3".repeat(100).toBytes()).tryGet()
        blocks = @[newBlock1, newBlock2, newBlock3]
        putHandles = await allFinished(blocks.mapIt(putBlockWithOverlay(bigRepo, it)))

      for handle in putHandles:
        check not handle.failed
        check handle.read.isOk

      let cidsIter = (await bigRepo.listBlocks(blockType = BlockType.Block)).tryGet()

      var count = 0
      for c in cidsIter:
        if cid =? await c:
          check (await bigRepo.hasBlock(cid)).tryGet()
          count.inc

      check count == 3

    test "listBlocks Manifest":
      let
        bigRepo =
          RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 5000'nb)
        newBlock = bt.Block.new("New Kids on the Block".toBytes()).tryGet()
        newBlock1 = bt.Block.new("1".repeat(100).toBytes()).tryGet()
        newBlock2 = bt.Block.new("2".repeat(100).toBytes()).tryGet()
        newBlock3 = bt.Block.new("3".repeat(100).toBytes()).tryGet()
        (manifest, tree) =
          makeManifestAndTree(@[newBlock, newBlock1, newBlock2, newBlock3]).tryGet()
        blocks = @[newBlock1, newBlock2, newBlock3]
        manifestBlock =
          Block.new(manifest.encode().tryGet(), codec = ManifestCodec).tryGet()
        treeBlock = Block.new(tree.encode()).tryGet()
        putHandles = await allFinished(
          (@[treeBlock, manifestBlock] & blocks).mapIt(bigRepo.putBlock(it))
        )

      for handle in putHandles:
        check not handle.failed
        check handle.read.isOk

      let cidsIter = (await bigRepo.listBlocks(blockType = BlockType.Manifest)).tryGet()

      var count = 0
      for c in cidsIter:
        if cid =? await c:
          check manifestBlock.cid == cid
          check (await bigRepo.hasBlock(cid)).tryGet()
          count.inc

      check count == 1

    test "listBlocks Both":
      let
        bigRepo =
          RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 5000'nb)
        newBlock = bt.Block.new("New Kids on the Block".toBytes()).tryGet()
        newBlock1 = bt.Block.new("1".repeat(100).toBytes()).tryGet()
        newBlock2 = bt.Block.new("2".repeat(100).toBytes()).tryGet()
        newBlock3 = bt.Block.new("3".repeat(100).toBytes()).tryGet()
        (manifest, tree) =
          makeManifestAndTree(@[newBlock, newBlock1, newBlock2, newBlock3]).tryGet()
        blocks = @[newBlock1, newBlock2, newBlock3]
        manifestBlock =
          Block.new(manifest.encode().tryGet(), codec = ManifestCodec).tryGet()
        treeBlock = Block.new(tree.encode()).tryGet()

      # Store manifest and tree blocks directly (not overlay API)
      let manifestHandles =
        await allFinished((@[treeBlock, manifestBlock]).mapIt(bigRepo.putBlock(it)))

      for handle in manifestHandles:
        check not handle.failed
        check handle.read.isOk

      # Store data blocks via overlay API
      let dataHandles =
        await allFinished(blocks.mapIt(putBlockWithOverlay(bigRepo, it)))

      for handle in dataHandles:
        check not handle.failed
        check handle.read.isOk

      let cidsIter = (await bigRepo.listBlocks(blockType = BlockType.Both)).tryGet()

      var count = 0
      for c in cidsIter:
        if cid =? await c:
          check (await bigRepo.hasBlock(cid)).tryGet()
          count.inc

      check count == 5

proc runFsSqliteTests() =
  let repoDir = createTempDir("archivist-", "-repostore")

  testRepoStore(
    "RepoStore FS+SQLite backend",
    repoDsProvider = proc(): KVStore =
      if not dirExists(repoDir):
        createDir(repoDir)
      let tp = Taskpool.new()
      FSKVStore.new(repoDir, tp, depth = 5).tryGet(),
    metaDsProvider = proc(): KVStore =
      let tp = Taskpool.new()
      SQLiteKVStore.new(SqliteMemory, tp).tryGet(),
    after = proc(): Future[void] {.async.} =
      os.removeDir(repoDir),
  )

runFsSqliteTests()
