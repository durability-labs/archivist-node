import std/sequtils
import std/strutils

import pkg/questionable
import pkg/questionable/results

import pkg/chronos
import pkg/stew/byteutils
import pkg/stew/bitseqs
import pkg/kvstore
import pkg/taskpools

import pkg/archivist/stores
import pkg/archivist/stores/repostore/operations
import pkg/archivist/stores/repostore/overlays/coders
import pkg/archivist/blocktype as bt
import pkg/archivist/clock
import pkg/archivist/utils

import pkg/archivist/merkletree/archivist

import ../../../asynctest
import ../../helpers
import ../../helpers/mockclock
import ../../examples

proc createTestBlock(size: int): bt.Block =
  bt.Block.new('a'.repeat(size).toBytes).tryGet()

proc putBlockWithOverlay(
    repo: RepoStore, blk: bt.Block
): Future[?!(Cid, Natural)] {.async.} =
  let (_, tree) = makeManifestAndTree(@[blk]).tryGet()
  let treeCid = tree.rootCid.tryGet()
  let proof = tree.getProof(0).tryGet()
  var blocks = BitSeq.init(1)
  blocks.setBit(0)

  (
    await repo.createOrUpdateOverlay(
      treeCid = treeCid, status = OverlayStatus.Completed, blocks = blocks
    )
  ).tryGet()
  (await repo.putLeafsAndBlocks(treeCid, @[(blk, 0.Natural, proof)])).tryGet()
  success((treeCid, 0.Natural))

suite "OverlayMetadata codecs":
  test "Should roundtrip with all fields":
    let cid = Cid.example
    var bits = BitSeq.init(10)
    bits.setBit(0)
    bits.setBit(9)

    let meta = OverlayMetadata(
      status: OverlayStatus.Completed, manifest: cid.some, expiry: 12345, blocks: bits
    )

    let decoded = OverlayMetadata.decode(meta.encode()).tryGet()
    check decoded.status == meta.status
    check decoded.expiry == meta.expiry
    check decoded.blocks == meta.blocks
    check decoded.manifest.get == cid

  test "Should roundtrip with no manifest":
    let meta = OverlayMetadata(
      status: OverlayStatus.Storing,
      manifest: Cid.none,
      expiry: 777,
      blocks: BitSeq.init(4),
    )

    let decoded = OverlayMetadata.decode(meta.encode()).tryGet()
    check decoded.status == meta.status
    check decoded.expiry == meta.expiry
    check decoded.blocks == meta.blocks
    check decoded.manifest.isNone

  test "Should roundtrip with empty blocks":
    let meta = OverlayMetadata(
      status: OverlayStatus.Completed,
      manifest: Cid.none,
      expiry: 999,
      blocks: BitSeq.init(0),
    )

    let decoded = OverlayMetadata.decode(meta.encode()).tryGet()
    check decoded.status == meta.status
    check decoded.expiry == meta.expiry
    check decoded.blocks == meta.blocks

  test "Should roundtrip all overlay statuses":
    for status in [
      OverlayStatus.Error, OverlayStatus.Storing, OverlayStatus.Completed,
      OverlayStatus.Deleting,
    ]:
      let meta = OverlayMetadata(
        status: status, manifest: Cid.none, expiry: 11, blocks: BitSeq.init(0)
      )

      let decoded = OverlayMetadata.decode(meta.encode()).tryGet()
      check decoded.status == status

suite "Overlay CRUD":
  var
    tp: Taskpool
    repoDs: KVStore
    metaDs: KVStore
    mockClock: MockClock
    repo: RepoStore

  let now: SecondsSince1970 = 123

  setup:
    tp = Taskpool.new()
    repoDs = SQLiteKVStore.new(SqliteMemory, tp).tryGet()
    metaDs = SQLiteKVStore.new(SqliteMemory, tp).tryGet()
    mockClock = MockClock.new()
    mockClock.set(now)
    repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 2000'nb)

  teardown:
    (await repoDs.close()).tryGet
    (await metaDs.close()).tryGet
    tp.shutdown()

  test "Should put and get overlay metadata":
    let
      treeCid = Cid.example
      manifestCid = createTestBlock(16).cid

    var bits = BitSeq.init(10)
    bits.setBit(0)
    bits.setBit(9)

    let meta = OverlayMetadata(
      status: OverlayStatus.Completed,
      manifest: manifestCid.some,
      expiry: now + 100,
      blocks: bits,
    )

    (await repo.putOverlayMetadata(treeCid, meta)).tryGet()
    let got = (await repo.getOverlayMetadata(treeCid)).tryGet()

    check got.status == meta.status
    check got.expiry == meta.expiry
    check got.blocks == meta.blocks
    check got.manifest.get == manifestCid

  test "Should update existing overlay metadata":
    let treeCid = Cid.example

    let meta1 = OverlayMetadata(
      status: OverlayStatus.Storing,
      manifest: Cid.none,
      expiry: now + 1,
      blocks: BitSeq.init(1),
    )
    (await repo.putOverlayMetadata(treeCid, meta1)).tryGet()

    var bits = BitSeq.init(2)
    bits.setBit(1)
    let meta2 = OverlayMetadata(
      status: OverlayStatus.Completed, manifest: Cid.none, expiry: now + 2, blocks: bits
    )
    (await repo.putOverlayMetadata(treeCid, meta2)).tryGet()

    let got = (await repo.getOverlayMetadata(treeCid)).tryGet()
    check got.status == meta2.status
    check got.expiry == meta2.expiry
    check got.blocks == meta2.blocks

  test "Should delete overlay metadata":
    let treeCid = Cid.example
    let meta = OverlayMetadata(
      status: OverlayStatus.Completed,
      manifest: Cid.none,
      expiry: now + 10,
      blocks: BitSeq.init(0),
    )

    (await repo.putOverlayMetadata(treeCid, meta)).tryGet()
    (await repo.deleteOverlayMetadata(treeCid)).tryGet()

    let res = await repo.getOverlayMetadata(treeCid)
    check res.isErr
    check res.error() of KVStoreKeyNotFound

  test "Should fail to delete non-existent overlay":
    let res = await repo.deleteOverlayMetadata(Cid.example)
    check res.isErr

  test "Should fail get for non-existent overlay with KVStoreKeyNotFound":
    let res = await repo.getOverlayMetadata(Cid.example)
    check res.isErr
    check res.error() of KVStoreKeyNotFound

suite "Overlay creation":
  var
    tp: Taskpool
    repoDs: KVStore
    metaDs: KVStore
    mockClock: MockClock
    repo: RepoStore

  let now: SecondsSince1970 = 123

  setup:
    tp = Taskpool.new()
    repoDs = SQLiteKVStore.new(SqliteMemory, tp).tryGet()
    metaDs = SQLiteKVStore.new(SqliteMemory, tp).tryGet()
    mockClock = MockClock.new()
    mockClock.set(now)
    repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 2000'nb)

  teardown:
    (await repoDs.close()).tryGet
    (await metaDs.close()).tryGet
    tp.shutdown()

  test "Should set expiry from clock and ttl":
    let treeCid = Cid.example
    let blocks = BitSeq.init(0)

    (
      await repo.createOrUpdateOverlay(
        treeCid = treeCid, status = OverlayStatus.Storing, blocks = blocks
      )
    ).tryGet()

    let meta = (await repo.getOverlayMetadata(treeCid)).tryGet()
    check meta.expiry == now + DefaultOverlayTtl.seconds

  test "Should store manifest cid":
    let
      treeCid = Cid.example
      manifestCid = createTestBlock(17).cid

    (
      await repo.createOrUpdateOverlay(
        treeCid = treeCid,
        status = OverlayStatus.Completed,
        blocks = BitSeq.init(1),
        manifest = manifestCid.some,
      )
    ).tryGet()

    let meta = (await repo.getOverlayMetadata(treeCid)).tryGet()
    check meta.manifest.get == manifestCid

  test "Should create unique tmp overlays":
    let tmpCid1 = (await repo.createTmpOverlay()).tryGet()
    let tmpCid2 = (await repo.createTmpOverlay()).tryGet()

    check tmpCid1 != tmpCid2

  test "Should create tmp overlay with storing status and no manifest":
    let tmpCid = (await repo.createTmpOverlay()).tryGet()
    let meta = (await repo.getOverlayMetadata(tmpCid)).tryGet()

    check meta.status == OverlayStatus.Storing
    check meta.manifest.isNone

  test "Should set tmp overlay expiry from clock and ttl":
    let tmpCid = (await repo.createTmpOverlay()).tryGet()
    let meta = (await repo.getOverlayMetadata(tmpCid)).tryGet()

    check meta.expiry == now + DefaultOverlayTtl.seconds

suite "Overlay listing":
  var
    tp: Taskpool
    repoDs: KVStore
    metaDs: KVStore
    mockClock: MockClock
    repo: RepoStore

  let now: SecondsSince1970 = 123

  setup:
    tp = Taskpool.new()
    repoDs = SQLiteKVStore.new(SqliteMemory, tp).tryGet()
    metaDs = SQLiteKVStore.new(SqliteMemory, tp).tryGet()
    mockClock = MockClock.new()
    mockClock.set(now)
    repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 2000'nb)

  teardown:
    (await repoDs.close()).tryGet
    (await metaDs.close()).tryGet
    tp.shutdown()

  test "Should list all overlays":
    let
      cid1 = createTestBlock(21).cid
      cid2 = createTestBlock(22).cid
      cid3 = createTestBlock(23).cid

    for (cid, status) in [
      (cid1, OverlayStatus.Completed),
      (cid2, OverlayStatus.Storing),
      (cid3, OverlayStatus.Error),
    ]:
      (
        await repo.createOrUpdateOverlay(
          treeCid = cid, status = status, blocks = BitSeq.init(1)
        )
      ).tryGet()

    let iter = (await repo.listOverlays()).tryGet()
    let cids = (await utils.collect(iter)).tryGet()

    check cids.len == 3
    check cids.anyIt(it == cid1)
    check cids.anyIt(it == cid2)
    check cids.anyIt(it == cid3)

  test "Should return empty list when no overlays exist":
    let iter = (await repo.listOverlays()).tryGet()
    let cids = (await utils.collect(iter)).tryGet()

    check cids.len == 0

  test "Should filter overlays by state":
    let
      cid1 = createTestBlock(31).cid
      cid2 = createTestBlock(32).cid
      cid3 = createTestBlock(33).cid

    for (cid, status) in [
      (cid1, OverlayStatus.Completed),
      (cid2, OverlayStatus.Storing),
      (cid3, OverlayStatus.Completed),
    ]:
      (
        await repo.createOrUpdateOverlay(
          treeCid = cid, status = status, blocks = BitSeq.init(1)
        )
      ).tryGet()

    let iter = (await repo.listOverlaysInState(OverlayStatus.Completed)).tryGet()
    let cids = (await utils.collect(iter)).tryGet()

    check cids.len == 2
    check cids.anyIt(it == cid1)
    check cids.anyIt(it == cid3)
    check cids.allIt(it != cid2)

  test "Should return empty list when state has no matches":
    let cid = createTestBlock(41).cid

    (
      await repo.createOrUpdateOverlay(
        treeCid = cid, status = OverlayStatus.Completed, blocks = BitSeq.init(1)
      )
    ).tryGet()

    let iter = (await repo.listOverlaysInState(OverlayStatus.Deleting)).tryGet()
    let cids = (await utils.collect(iter)).tryGet()

    check cids.len == 0

  test "Should list overlays sorted by expiry ascending":
    let
      cid1 = createTestBlock(51).cid
      cid2 = createTestBlock(52).cid
      cid3 = createTestBlock(53).cid

    for (cid, status) in [
      (cid1, OverlayStatus.Storing),
      (cid2, OverlayStatus.Storing),
      (cid3, OverlayStatus.Storing),
    ]:
      (
        await repo.createOrUpdateOverlay(
          treeCid = cid, status = status, blocks = BitSeq.init(1), expiry = 50.seconds
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
        await repo.createOrUpdateOverlay(
          treeCid = cid, status = OverlayStatus.Completed, blocks = BitSeq.init(1)
        )
      ).tryGet()

    let firstPage = (await repo.listOverlaysByExpiry(limit = 2, offset = 0)).tryGet()
    let secondPage = (await repo.listOverlaysByExpiry(limit = 2, offset = 2)).tryGet()

    check firstPage.len == 2
    check secondPage.len == 2
    for (cid, _) in firstPage:
      check secondPage.allIt(it[0] != cid)

suite "Overlay lifecycle":
  var
    tp: Taskpool
    repoDs: KVStore
    metaDs: KVStore
    mockClock: MockClock
    repo: RepoStore

  let now: SecondsSince1970 = 123

  setup:
    tp = Taskpool.new()
    repoDs = SQLiteKVStore.new(SqliteMemory, tp).tryGet()
    metaDs = SQLiteKVStore.new(SqliteMemory, tp).tryGet()
    mockClock = MockClock.new()
    mockClock.set(now)
    repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 2000'nb)

  teardown:
    (await repoDs.close()).tryGet
    (await metaDs.close()).tryGet
    tp.shutdown()

  test "Should drop overlay and remove leafs, blocks, and metadata":
    let blk = createTestBlock(120)
    let (treeCid, index) = (await putBlockWithOverlay(repo, blk)).tryGet()

    (await repo.dropOverlay(treeCid)).tryGet()

    let leafResult = await repo.getLeafMetadata(treeCid, index)
    let blockResult = await repo.getBlock(blk.cid)
    let overlayResult = await repo.getOverlayMetadata(treeCid)

    check leafResult.isErr
    check leafResult.error() of BlockNotFoundError
    check blockResult.isErr
    check blockResult.error() of BlockNotFoundError
    check overlayResult.isErr
    check overlayResult.error() of KVStoreKeyNotFound

  test "Should only decrement refcount for shared blocks when one overlay is dropped":
    let
      shared = createTestBlock(121)
      extra1 = createTestBlock(122)
      extra2 = createTestBlock(123)
      (_, tree1) = makeManifestAndTree(@[shared, extra1]).tryGet()
      (_, tree2) = makeManifestAndTree(@[extra2, shared]).tryGet()
      treeCid1 = tree1.rootCid.tryGet()
      treeCid2 = tree2.rootCid.tryGet()
      proof1 = tree1.getProof(0).tryGet()
      proof2 = tree2.getProof(1).tryGet()

    (
      await repo.createOrUpdateOverlay(
        treeCid = treeCid1, status = OverlayStatus.Completed, blocks = BitSeq.init(2)
      )
    ).tryGet()

    (
      await repo.createOrUpdateOverlay(
        treeCid = treeCid2, status = OverlayStatus.Completed, blocks = BitSeq.init(2)
      )
    ).tryGet()

    (await repo.putLeafsAndBlocks(treeCid1, @[(shared, 0.Natural, proof1)])).tryGet()
    (await repo.putLeafsAndBlocks(treeCid2, @[(shared, 1.Natural, proof2)])).tryGet()
    check (await repo.blockRefCount(shared.cid)).tryGet() == 2.Natural

    (await repo.dropOverlay(treeCid1)).tryGet()

    check (await repo.blockRefCount(shared.cid)).tryGet() == 1.Natural
    check (await repo.getBlock(shared.cid)).isOk
    check (await repo.getOverlayMetadata(treeCid1)).isErr

  test "Should drop empty overlay metadata":
    let treeCid = Cid.example

    (
      await repo.createOrUpdateOverlay(
        treeCid = treeCid, status = OverlayStatus.Storing, blocks = BitSeq.init(0)
      )
    ).tryGet()

    (await repo.dropOverlay(treeCid)).tryGet()

    let res = await repo.getOverlayMetadata(treeCid)
    check res.isErr
    check res.error() of KVStoreKeyNotFound

  test "Should finalize overlay by moving metadata and leaves":
    let
      blk = createTestBlock(124)
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      realTreeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()
      tmpCid = (await repo.createTmpOverlay()).tryGet()

    (await repo.putLeafsAndBlocks(tmpCid, @[(blk, 0.Natural, proof)])).tryGet()
    (await repo.finalizeOverlay(tmpCid, realTreeCid)).tryGet()

    let
      realOverlay = (await repo.getOverlayMetadata(realTreeCid)).tryGet()
      leaf = (await repo.getLeafMetadata(realTreeCid, 0.Natural)).tryGet()

    check realOverlay.status == OverlayStatus.Storing
    check realOverlay.blocks[0]
    check leaf.blkCid == blk.cid

  test "Should remove old tmp overlay metadata after finalize":
    let
      blk = createTestBlock(125)
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      realTreeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()
      tmpCid = (await repo.createTmpOverlay()).tryGet()

    (await repo.putLeafsAndBlocks(tmpCid, @[(blk, 0.Natural, proof)])).tryGet()
    (await repo.finalizeOverlay(tmpCid, realTreeCid)).tryGet()

    let res = await repo.getOverlayMetadata(tmpCid)
    check res.isErr
    check res.error() of KVStoreKeyNotFound

  test "Should provide block and proof under new tree after finalize":
    let
      blk = createTestBlock(126)
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      realTreeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()
      tmpCid = (await repo.createTmpOverlay()).tryGet()

    (await repo.putLeafsAndBlocks(tmpCid, @[(blk, 0.Natural, proof)])).tryGet()
    (await repo.finalizeOverlay(tmpCid, realTreeCid)).tryGet()

    let (gotBlock, gotProof) =
      (await repo.getBlockAndProof(realTreeCid, 0.Natural)).tryGet()
    check gotBlock.cid == blk.cid
    check gotProof.index == proof.index
    check gotProof.nleaves == proof.nleaves
