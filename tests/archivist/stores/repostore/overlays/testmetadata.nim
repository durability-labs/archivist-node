import std/os
import std/tempfiles
import std/sequtils

import pkg/questionable
import pkg/questionable/results

import pkg/chronos
import pkg/taskpools
import pkg/stew/bitseqs
import pkg/kvstore
import pkg/kvstore/fsds

import pkg/archivist/stores
import pkg/archivist/stores/repostore/operations
import pkg/archivist/stores/repostore/overlays/coders
import pkg/archivist/stores/repostore/types
import pkg/archivist/blocktype as bt
import pkg/archivist/clock
import pkg/archivist/utils

import pkg/archivist/merkletree/archivist

import ../../../../asynctest
import ../../../helpers
import ../../../helpers/mockclock
import ../../../examples

import ./helpers

proc testMetadata*(
    name: string,
    repoDsProvider: KVStoreProvider,
    metaDsProvider: KVStoreProvider,
    before: Before = nil,
    after: After = nil,
) =
  asyncchecksuite name:
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
          2000'nb)

    teardown:
      (await repoDs.close()).tryGet
      (await metaDs.close()).tryGet
      if not isNil(after):
        await after()

    test "Should put and get overlay metadata":
      let treeCid = Cid.example

      var bits = BitSeq.init(10)
      bits.setBit(0)
      bits.setBit(9)

      let meta = OverlayMetadata(status: Completed, expiry: now + 100, blocks: bits)

      (
        await repo.putOverlay(
          treeCid, status = meta.status.some, blocks = meta.blocks, expiry = meta.expiry
        )
      ).tryGet()
      let got = (await repo.getOverlay(treeCid)).tryGet()

      check got.status == meta.status
      check got.expiry == meta.expiry
      check got.blocks == meta.blocks

    test "Should update existing overlay metadata":
      let treeCid = Cid.example

      let meta1 =
        OverlayMetadata(status: Storing, expiry: now + 1, blocks: BitSeq.init(1))

      (
        await repo.putOverlay(
          treeCid,
          status = meta1.status.some,
          blocks = meta1.blocks,
          expiry = meta1.expiry,
        )
      ).tryGet()

      var bits = BitSeq.init(2)
      bits.setBit(1)
      let meta2 = OverlayMetadata(status: Completed, expiry: now + 2, blocks: bits)

      (
        await repo.putOverlay(
          treeCid,
          status = meta2.status.some,
          blocks = meta2.blocks,
          expiry = meta2.expiry,
        )
      ).tryGet()

      let got = (await repo.getOverlay(treeCid)).tryGet()
      check got.status == meta2.status
      check got.expiry == meta2.expiry
      check got.blocks == meta2.blocks

    test "Should delete overlay metadata":
      let treeCid = Cid.example
      let meta =
        OverlayMetadata(status: Completed, expiry: now + 10, blocks: BitSeq.init(0))

      (
        await repo.putOverlay(
          treeCid, status = meta.status.some, blocks = meta.blocks, expiry = meta.expiry
        )
      ).tryGet()
      (await repo.deleteOverlay(treeCid)).tryGet()

      let res = await repo.getOverlay(treeCid)
      check res.isErr
      check res.error() of KVStoreKeyNotFound

    test "Should fail to delete non-existent overlay":
      let res = await repo.deleteOverlay(Cid.example)
      check res.isErr

    test "Should fail get for non-existent overlay with KVStoreKeyNotFound":
      let res = await repo.getOverlay(Cid.example)
      check res.isErr
      check res.error() of KVStoreKeyNotFound

    test "hasBlock behavior across states":
      let
        blk = createTestBlock(100)
        (_, tree) = makeManifestAndTree(@[blk]).tryGet()
        treeCid = tree.rootCid.tryGet()
        proof = tree.getProof(0).tryGet()

      (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

      # Not set, no block
      check (await repo.hasBlock(treeCid, 0.Natural)).tryGet() == false

      # Set with block
      (await repo.putBlocks(treeCid, @[(blk, 0.Natural, proof.some)])).tryGet()
      check (await repo.hasBlock(treeCid, 0.Natural)).tryGet() == true
      check repo.quotaUsedBytes == 100.NBytes
      check repo.totalBlocks == 1.Natural

      # Out of range (fast-path, no store hit)
      check (await repo.hasBlock(treeCid, 10.Natural)).tryGet() == false
      let leafRes = await repo.getLeafMetadata(treeCid, 10.Natural)
      check leafRes.isErr
      check leafRes.error() of BlockNotFoundError

    test "Shared blocks across overlays maintain correct BitSeq":
      let
        shared = createTestBlock(200)
        (_, tree1) = makeManifestAndTree(@[shared]).tryGet()
        treeCid1 = tree1.rootCid.tryGet()
        proof1 = tree1.getProof(0).tryGet()

      (await repo.putOverlay(treeCid1, status = Completed.some)).tryGet()
      (await repo.putBlocks(treeCid1, @[(shared, 0.Natural, proof1.some)])).tryGet()

      let meta1 = (await repo.getOverlay(treeCid1)).tryGet()
      check meta1.blocks[0] == true

      let refCount = (await repo.blockRefCount(shared.cid)).tryGet()
      check refCount == 1.Natural

      (await repo.dropOverlay(treeCid1)).tryGet()

      let blkRes = await repo.getBlock(shared.cid)
      check blkRes.isErr
      check repo.quotaUsedBytes == 0.NBytes
      check repo.totalBlocks == 0.Natural

    test "Should handle non-contiguous indices in putBlocks (BitSeq length fix)":
      let
        innerRepo =
          RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 2000'nb)
        dataset =
          (await makeRandomBlocks(datasetSize = 2560, blockSize = 256'nb)).tryGet
        blk = dataset[0]
        (_, tree) = makeManifestAndTree(dataset).tryGet()
        treeCid = tree.rootCid.tryGet()

      # Create overlay with 10 blocks, but only insert at index 5
      var blocks = BitSeq.init(10)

      (
        await innerRepo.putOverlay(
          treeCid = treeCid, status = Completed.some, blocks = blocks
        )
      ).tryGet()

      # Put only index 5 (non-contiguous)
      let proof = tree.getProof(5).tryGet()
      (await innerRepo.putBlocks(treeCid, @[(blk, 5.Natural, proof.some)])).tryGet()

      # Verify block was stored
      check (await innerRepo.getBlock(blk.cid)).isOk
      check innerRepo.quotaUsedBytes == 256.NBytes

      # Verify overlay has correct bit set
      let overlayMeta = (await innerRepo.getOverlay(treeCid)).tryGet()
      check overlayMeta.blocks.len == 10
      check overlayMeta.blocks[5] == true

    test "Should create unique tmp overlays":
      let tmpCid1 = (await repo.createTmpOverlay()).tryGet()
      let tmpCid2 = (await repo.createTmpOverlay()).tryGet()

      check tmpCid1 != tmpCid2

    test "Should create tmp overlay with storing status":
      let tmpCid = (await repo.createTmpOverlay()).tryGet()
      let meta = (await repo.getOverlay(tmpCid)).tryGet()

      check meta.status == Storing

    test "Should set tmp overlay expiry from clock and ttl":
      let tmpCid = (await repo.createTmpOverlay()).tryGet()
      let meta = (await repo.getOverlay(tmpCid)).tryGet()

      check meta.expiry == now + DefaultOverlayTtl

    test "Should list all overlays":
      let
        cid1 = createTestBlock(21).cid
        cid2 = createTestBlock(22).cid
        cid3 = createTestBlock(23).cid

      for (cid, status) in [(cid1, Completed), (cid2, Storing), (cid3, Failure)]:
        (
          await repo.putOverlay(
            treeCid = cid, status = status.some, blocks = BitSeq.init(1)
          )
        ).tryGet()

      let iter = (await repo.listOverlays()).tryGet()
      let cids = await collectAsync(iter)

      check cids.len == 3
      check cids.anyIt(it == cid1)
      check cids.anyIt(it == cid2)
      check cids.anyIt(it == cid3)

    test "Should return empty list when no overlays exist":
      let iter = (await repo.listOverlays()).tryGet()
      let cids = await collectAsync(iter)

      check cids.len == 0

    test "Should filter overlays by state":
      let
        cid1 = createTestBlock(31).cid
        cid2 = createTestBlock(32).cid
        cid3 = createTestBlock(33).cid

      for (cid, status) in [(cid1, Completed), (cid2, Storing), (cid3, Completed)]:
        (
          await repo.putOverlay(
            treeCid = cid, status = status.some, blocks = BitSeq.init(1)
          )
        ).tryGet()

      let iter = (await repo.listOverlaysInState(Completed)).tryGet()
      let cids = await collectAsync(iter)

      check cids.len == 2
      check cids.anyIt(it == cid1)
      check cids.anyIt(it == cid3)
      check cids.allIt(it != cid2)

    test "Should return empty list when state has no matches":
      let cid = createTestBlock(41).cid

      (
        await repo.putOverlay(
          treeCid = cid, status = Completed.some, blocks = BitSeq.init(1)
        )
      ).tryGet()

      let iter = (await repo.listOverlaysInState(Deleting)).tryGet()
      let cids = await collectAsync(iter)

      check cids.len == 0

    test "Should list overlays sorted by expiry ascending":
      let
        cid1 = createTestBlock(51).cid
        cid2 = createTestBlock(52).cid
        cid3 = createTestBlock(53).cid

      for (cid, status) in [
        (cid1, Storing.some), (cid2, Storing.some), (cid3, Storing.some)
      ]:
        (
          await repo.putOverlay(
            treeCid = cid, status = status, blocks = BitSeq.init(1), expiry = 50
          )
        ).tryGet()

      let overlays = (await repo.listOverlaysByExpiry(limit = 10, offset = 0)).tryGet()
      let overlayCids = overlays.mapIt(it[0])

      check overlays.len == 3
      check overlayCids == @[cid2, cid3, cid1]

    test "Should apply limit and offset for expiry listing":
      let
        cid1 = createTestBlock(61).cid
        cid2 = createTestBlock(62).cid
        cid3 = createTestBlock(63).cid
        cid4 = createTestBlock(64).cid

      for cid in [cid1, cid2, cid3, cid4]:
        (
          await repo.putOverlay(
            treeCid = cid, status = Completed.some, blocks = BitSeq.init(1)
          )
        ).tryGet()

      let firstPage = (await repo.listOverlaysByExpiry(limit = 2, offset = 0)).tryGet()
      let secondPage = (await repo.listOverlaysByExpiry(limit = 2, offset = 2)).tryGet()

      check firstPage.len == 2
      check secondPage.len == 2
      for (cid, _) in firstPage:
        check secondPage.allIt(it[0] != cid)

proc runFsSqliteTests() =
  let repoDir = createTempDir("archivist-", "-repostore")

  testMetadata(
    "Overlay metadata FS+SQLite backend",
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
