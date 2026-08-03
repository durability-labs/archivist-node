import std/os
import std/tempfiles

import pkg/questionable
import pkg/questionable/results

import pkg/chronos
import pkg/stew/bitseqs
import pkg/kvstore
import pkg/kvstore/fsds
import pkg/taskpools

import pkg/archivist/stores
import pkg/archivist/stores/repostore/operations
import pkg/archivist/stores/repostore/types
import pkg/archivist/clock

import pkg/archivist/merkletree/archivist

import ../../../../asynctest
import ../../../helpers
import ../../../helpers/mockclock
import ../../../examples

import ./helpers

type KVStoreProvider* = proc(): KVStore {.gcsafe.}

proc testConcurrent*(
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

    let now: SecondsSince1970 = 1000

    setup:
      if not isNil(before):
        await before()
      repoDs = repoDsProvider()
      metaDs = metaDsProvider()
      mockClock = MockClock.new()
      mockClock.set(now)
      repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes =
          10000'nb)

    teardown:
      (await repoDs.close()).tryGet
      (await metaDs.close()).tryGet
      if not isNil(after):
        await after()

    test "Concurrent put operations on same overlay are serialized":
      let
        blk1 = createTestBlock(800)
        blk2 = createTestBlock(801)
        blk3 = createTestBlock(802)
        (_, tree) = makeManifestAndTree(@[blk1, blk2, blk3]).tryGet()
        treeCid = tree.rootCid.tryGet()
        proof1 = tree.getProof(0).tryGet()
        proof2 = tree.getProof(1).tryGet()
        proof3 = tree.getProof(2).tryGet()

      (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

      let
        put1Future = repo.putBlocks(treeCid, @[(blk1, 0.Natural, proof1.some)])
        put2Future = repo.putBlocks(treeCid, @[(blk2, 1.Natural, proof2.some)])
        put3Future = repo.putBlocks(treeCid, @[(blk3, 2.Natural, proof3.some)])

      await allFutures(@[put1Future, put2Future, put3Future])

      check (await put1Future).isOk
      check (await put2Future).isOk
      check (await put3Future).isOk

      let meta = (await repo.getOverlay(treeCid)).tryGet()
      check:
        meta.blocks[0] == true
        meta.blocks[1] == true
        meta.blocks[2] == true

      let inconsistencies = (await repo.verifyBlockBitState(treeCid)).tryGet()
      check inconsistencies.len == 0

      check repo.quotaUsedBytes == NBytes(800 + 801 + 802)
      check repo.totalBlocks == 3.Natural

    test "Sequential CAS updates handle retries correctly":
      let
        blk1 = createTestBlock(840)
        blk2 = createTestBlock(841)
        blk3 = createTestBlock(842)
        (_, tree) = makeManifestAndTree(@[blk1, blk2, blk3]).tryGet()
        treeCid = tree.rootCid.tryGet()
        proof1 = tree.getProof(0).tryGet()
        proof2 = tree.getProof(1).tryGet()
        proof3 = tree.getProof(2).tryGet()

      (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

      let
        blocks = @[blk1, blk2, blk3]
        proofs = @[proof1, proof2, proof3]
      for i in 0 ..< 3:
        (await repo.putBlocks(treeCid, @[(blocks[i], i.Natural, proofs[i].some)])).tryGet()

        let meta = (await repo.getOverlay(treeCid)).tryGet()
        check meta.blocks[i] == true

        let inconsistencies = (await repo.verifyBlockBitState(treeCid)).tryGet()
        check inconsistencies.len == 0

    test "Concurrent overlay metadata updates preserve latest values":
      let treeCid = Cid.example

      let
        update1 = repo.putOverlay(
          treeCid, status = Storing.some, blocks = BitSeq.init(1), expiry = 100
        )
        update2 = repo.putOverlay(
          treeCid, status = Completed.some, blocks = BitSeq.init(2), expiry = 200
        )

      let
        res1 = await update1
        res2 = await update2

      check res1.isOk or res2.isOk

      let meta = (await repo.getOverlay(treeCid)).tryGet()
      check meta.status in {Storing, Completed}

    test "Concurrent putBlocks and dropOverlay on different overlays":
      let
        blk1 = createTestBlock(900)
        blk2 = createTestBlock(901)
        blk3 = createTestBlock(902)
        blk4 = createTestBlock(903)
        (_, treeA) = makeManifestAndTree(@[blk1, blk2]).tryGet()
        (_, treeB) = makeManifestAndTree(@[blk3, blk4]).tryGet()
        treeCidA = treeA.rootCid.tryGet()
        treeCidB = treeB.rootCid.tryGet()
        proofA1 = treeA.getProof(0).tryGet()
        proofA2 = treeA.getProof(1).tryGet()
        proofB1 = treeB.getProof(0).tryGet()
        proofB2 = treeB.getProof(1).tryGet()

      (
        await repo.putOverlay(
          treeCid = treeCidA, status = Completed.some, blocks = BitSeq.init(2)
        )
      ).tryGet()

      (
        await repo.putOverlay(
          treeCid = treeCidB, status = Completed.some, blocks = BitSeq.init(2)
        )
      ).tryGet()

      (await repo.putBlocks(treeCidB, @[(blk3, 0.Natural, proofB1.some)])).tryGet()
      (await repo.putBlocks(treeCidB, @[(blk4, 1.Natural, proofB2.some)])).tryGet()

      let
        putFuture = repo.putBlocks(
          treeCidA, @[(blk1, 0.Natural, proofA1.some), (blk2, 1.Natural, proofA2.some)]
        )
        dropFuture = repo.dropOverlay(treeCidB)

      await allFutures(@[putFuture, dropFuture])

      check (await putFuture).isOk
      check (await dropFuture).isOk

      let metaA = (await repo.getOverlay(treeCidA)).tryGet()
      check:
        metaA.blocks[0] == true
        metaA.blocks[1] == true

      let inconsistenciesA = (await repo.verifyBlockBitState(treeCidA)).tryGet()
      check inconsistenciesA.len == 0

      check (await repo.getOverlay(treeCidB)).isErr
      check (await repo.getBlock(blk3.cid)).isErr
      check (await repo.getBlock(blk4.cid)).isErr

      check repo.quotaUsedBytes == NBytes(900 + 901)
      check repo.totalBlocks == 2.Natural

    test "putBlocks aborts when delete started first":
      let
        blk1 = createTestBlock(910)
        blk2 = createTestBlock(911)
        blk3 = createTestBlock(912)
        (_, tree) = makeManifestAndTree(@[blk1, blk2, blk3]).tryGet()
        treeCid = tree.rootCid.tryGet()
        proof1 = tree.getProof(0).tryGet()
        proof2 = tree.getProof(1).tryGet()

      (
        await repo.putOverlay(
          treeCid = treeCid, status = Deleting.some, blocks = BitSeq.init(3)
        )
      ).tryGet()

      let putResult = await repo.putBlocks(
        treeCid, @[(blk1, 0.Natural, proof1.some), (blk2, 1.Natural, proof2.some)]
      )

      check putResult.isErr
      check putResult.error() of OverlayDeletingError

    test "putBlocks aborts when delete starts mid-operation":
      let
        blk1 = createTestBlock(920)
        blk2 = createTestBlock(921)
        blk3 = createTestBlock(922)
        (_, tree) = makeManifestAndTree(@[blk1, blk2, blk3]).tryGet()
        treeCid = tree.rootCid.tryGet()
        proof1 = tree.getProof(0).tryGet()
        proof2 = tree.getProof(1).tryGet()
        proof3 = tree.getProof(2).tryGet()

      (
        await repo.putOverlay(
          treeCid = treeCid, status = Completed.some, blocks = BitSeq.init(3)
        )
      ).tryGet()

      # TODO: the correct way to test this is with a mock of the kvstore,
      # but that breaks the structure of the tests and it's a significant
      # amount of effort - but this is one of the few legitimate usages
      # of mocking ;)
      let putFuture = repo.putBlocks(
        treeCid,
        @[
          (blk1, 0.Natural, proof1.some),
          (blk2, 1.Natural, proof2.some),
          (blk3, 2.Natural, proof3.some),
        ],
      )
      (await repo.dropOverlay(treeCid)).tryGet

      let putResult = await putFuture

      if putResult.isErr:
        check putResult.error() of OverlayDeletingError

      check (await repo.getOverlay(treeCid)).isErr

      check repo.quotaUsedBytes == 0.NBytes
      check repo.totalBlocks == 0.Natural

proc runFsSqliteTests() =
  let repoDir = createTempDir("archivist-", "-repostore")

  testConcurrent(
    "Concurrent overlay updates FS+SQLite backend",
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
