import std/os
import std/tempfiles

import pkg/questionable
import pkg/questionable/results

import pkg/chronos
import pkg/taskpools
import pkg/stew/bitseqs
import pkg/kvstore
import pkg/kvstore/fsds
import pkg/libp2p/multicodec

import pkg/archivist/stores
import pkg/archivist/stores/repostore/operations
import pkg/archivist/stores/repostore/types
import pkg/archivist/blocktype as bt
import pkg/archivist/clock

import pkg/archivist/merkletree/archivist

import ../../../../asynctest
import ../../../helpers
import ../../../helpers/mockclock
import ../../../examples

import ./helpers

proc testCells*(
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

    test "Cell leaf stores metadata and refcount behavior":
      let
        blk1 = createTestBlock(400)
        blk2 = createTestBlock(401)
        cellCid1 = bt.Block.new("cell1".toBytes).tryGet().cid
        cellCid2 = bt.Block.new("cell2".toBytes).tryGet().cid
        (_, tree) = makeManifestAndTree(@[blk1, blk2]).tryGet()
        treeCid = tree.rootCid.tryGet()
        proof1 = tree.getProof(0).tryGet()
        proof2 = tree.getProof(1).tryGet()

      (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

      (
        await repo.putCellCidsAndProofs(
          treeCid,
          @[
            (0.Natural, cellCid1, blk1.cid, proof1),
            (1.Natural, cellCid2, blk2.cid, proof2),
          ],
        )
      ).tryGet()

      let
        leaf1 = (await repo.getLeafMetadata(treeCid, 0.Natural)).tryGet()
        leaf2 = (await repo.getLeafMetadata(treeCid, 1.Natural)).tryGet()
        blkRefCount1 = (await repo.blockRefCount(blk1.cid)).tryGet()
        blkRefCount2 = (await repo.blockRefCount(blk2.cid)).tryGet()
        cellRefCountRes1 = await repo.blockRefCount(cellCid1)
        cellRefCountRes2 = await repo.blockRefCount(cellCid2)

      check:
        leaf1.isCell == true
        leaf1.cellCid == cellCid1
        leaf1.blkCid == blk1.cid
        leaf2.isCell == true
        leaf2.cellCid == cellCid2
        leaf2.blkCid == blk2.cid
        blkRefCount1 == 1
        blkRefCount2 == 1
        cellRefCountRes1.isErr
        cellRefCountRes2.isErr

    test "Cell leaf refcount increments and decrements correctly":
      let
        blk = createTestBlock(402)
        blk2 = createTestBlock(403)
        cellCid1 = bt.Block.new("cell1".toBytes).tryGet().cid
        cellCid2 = bt.Block.new("cell2".toBytes).tryGet().cid
        (_, tree) = makeManifestAndTree(@[blk, blk2]).tryGet()
        treeCid = tree.rootCid.tryGet()
        proof1 = tree.getProof(0).tryGet()
        proof2 = tree.getProof(1).tryGet()

      (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

      (
        await repo.putCellCidsAndProofs(
          treeCid,
          @[
            (0.Natural, cellCid1, blk.cid, proof1),
            (1.Natural, cellCid2, blk.cid, proof2),
          ],
        )
      ).tryGet()

      let refCountBefore = (await repo.blockRefCount(blk.cid)).tryGet()
      check refCountBefore == 2

      (await repo.delLeafBlockMetadata(treeCid, @[0.Natural])).tryGet()

      let refCountAfter = (await repo.blockRefCount(blk.cid)).tryGet()
      check refCountAfter == 1

    test "Cell and regular leaves coexist":
      let
        blk1 = createTestBlock(410)
        blk2 = createTestBlock(411)
        cellCid = bt.Block.new("cell".toBytes).tryGet().cid
        (_, tree) = makeManifestAndTree(@[blk1, blk2]).tryGet()
        treeCid = tree.rootCid.tryGet()
        proof1 = tree.getProof(0).tryGet()
        proof2 = tree.getProof(1).tryGet()

      (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

      (
        await repo.putCellCidsAndProofs(
          treeCid, @[(0.Natural, cellCid, blk1.cid, proof1)]
        )
      ).tryGet()
      (await repo.putCidsAndProofs(treeCid, @[(1.Natural, blk2.cid, proof2)])).tryGet()

      let
        leaf1 = (await repo.getLeafMetadata(treeCid, 0.Natural)).tryGet()
        leaf2 = (await repo.getLeafMetadata(treeCid, 1.Natural)).tryGet()

      check:
        leaf1.isCell == true
        leaf1.cellCid == cellCid
        leaf1.blkCid == blk1.cid
        leaf2.isCell == false

    test "Empty blkCid skips refcount in cell and regular paths":
      let
        realBlk = createTestBlock(700)
        cellCid1 = bt.Block.new("cell1".toBytes).tryGet().cid
        cellCid2 = bt.Block.new("cell2".toBytes).tryGet().cid
        emptyBlkCid = emptyCid(CIDv1, multiCodec("sha2-256"), BlockCodec).tryGet()
        (_, tree) = makeManifestAndTree(@[realBlk, realBlk]).tryGet()
        treeCid = tree.rootCid.tryGet()
        proof1 = tree.getProof(0).tryGet()
        proof2 = tree.getProof(1).tryGet()

      (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

      (
        await repo.putCellCidsAndProofs(
          treeCid,
          @[
            (0.Natural, cellCid1, realBlk.cid, proof1),
            (1.Natural, cellCid2, emptyBlkCid, proof2),
          ],
        )
      ).tryGet()

      let
        leaf1 = (await repo.getLeafMetadata(treeCid, 0.Natural)).tryGet()
        leaf2 = (await repo.getLeafMetadata(treeCid, 1.Natural)).tryGet()
        realRefCountBefore = (await repo.blockRefCount(realBlk.cid)).tryGet()
        emptyRefCountRes = await repo.blockRefCount(emptyBlkCid)

      check:
        leaf1.blkCid == realBlk.cid
        leaf1.blkCid.isEmpty == false
        leaf2.isCell == true
        leaf2.cellCid == cellCid2
        leaf2.blkCid == emptyBlkCid
        leaf2.blkCid.isEmpty == true
        realRefCountBefore == 1
        emptyRefCountRes.isErr

      (await repo.delLeafBlockMetadata(treeCid, @[0.Natural, 1.Natural])).tryGet()

      let refCountAfter = await repo.blockRefCount(realBlk.cid)
      check refCountAfter.isErr

      let
        (_, tree2) = makeManifestAndTree(@[realBlk]).tryGet()
        treeCid2 = tree2.rootCid.tryGet()
        proof3 = tree2.getProof(0).tryGet()
        emptyBlk = bt.Block.new(newSeq[byte](0)).tryGet()

      check emptyBlk.cid.isEmpty == true

      (await repo.putOverlay(treeCid2, status = Completed.some)).tryGet()
      (await repo.putBlocks(treeCid2, @[(emptyBlk, 0.Natural, proof3.some)])).tryGet()

      let leaf3 = (await repo.getLeafMetadata(treeCid2, 0.Natural)).tryGet()
      check:
        leaf3.blkCid.isEmpty == true
        leaf3.isCell == false

    test "Should correctly handle multi-index delete with same block CID (refCount aggregation)":
      let
        innerRepo =
          RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 2000'nb)
        blk = createTestBlock(256)

      let (_, tree) = makeManifestAndTree(@[blk, blk, blk, blk, blk, blk]).tryGet()
      let treeCid = tree.rootCid.tryGet()

      var blocks = BitSeq.init(6)
      blocks.setBit(1)
      blocks.setBit(3)
      blocks.setBit(5)

      (
        await innerRepo.putOverlay(
          treeCid = treeCid, status = Completed.some, blocks = blocks
        )
      ).tryGet()

      let
        proof1 = tree.getProof(1).tryGet()
        proof3 = tree.getProof(3).tryGet()
        proof5 = tree.getProof(5).tryGet()

      (
        await innerRepo.putBlocks(
          treeCid,
          @[
            (blk, 1.Natural, proof1.some),
            (blk, 3.Natural, proof3.some),
            (blk, 5.Natural, proof5.some),
          ],
        )
      ).tryGet()

      check (await innerRepo.blockRefCount(blk.cid)).tryGet() == 3.Natural
      check innerRepo.quotaUsedBytes == 256.NBytes
      check innerRepo.totalBlocks == 1.Natural

      (
        await innerRepo.delLeafBlockMetadata(
          treeCid, @[1.Natural, 3.Natural, 5.Natural]
        )
      ).tryGet()

      check not (await blk.cid in innerRepo)
      check innerRepo.quotaUsedBytes == 0.NBytes
      check innerRepo.totalBlocks == 0.Natural

proc runFsSqliteTests() =
  let repoDir = createTempDir("archivist-", "-repostore")

  testCells(
    "Cell handling FS+SQLite backend",
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
