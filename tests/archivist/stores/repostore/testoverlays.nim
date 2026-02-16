import std/sequtils
import std/strutils
import std/random

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
    await repo.putOverlayMetadata(
      treeCid = treeCid, status = Completed.some, blocks = blocks
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

    let meta = OverlayMetadata(status: Completed, expiry: 12345, blocks: bits)

    let decoded = OverlayMetadata.decode(meta.encode()).tryGet()
    check decoded.status == meta.status
    check decoded.expiry == meta.expiry
    check decoded.blocks == meta.blocks

  test "Should roundtrip with empty blocks":
    let meta = OverlayMetadata(status: Completed, expiry: 999, blocks: BitSeq.init(0))

    let decoded = OverlayMetadata.decode(meta.encode()).tryGet()
    check decoded.status == meta.status
    check decoded.expiry == meta.expiry
    check decoded.blocks == meta.blocks

  test "Should roundtrip all overlay statuses":
    for status in [
      OverlayStatus.Failure, OverlayStatus.Storing, OverlayStatus.Completed,
      OverlayStatus.Deleting,
    ]:
      let meta = OverlayMetadata(status: status, expiry: 11, blocks: BitSeq.init(0))

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
    let treeCid = Cid.example

    var bits = BitSeq.init(10)
    bits.setBit(0)
    bits.setBit(9)

    let meta = OverlayMetadata(status: Completed, expiry: now + 100, blocks: bits)

    (
      await repo.putOverlayMetadata(
        treeCid, status = meta.status.some, blocks = meta.blocks, expiry = meta.expiry
      )
    ).tryGet()
    let got = (await repo.getOverlayMetadata(treeCid)).tryGet()

    check got.status == meta.status
    check got.expiry == meta.expiry
    check got.blocks == meta.blocks

  test "Should update existing overlay metadata":
    let treeCid = Cid.example

    let meta1 =
      OverlayMetadata(status: Storing, expiry: now + 1, blocks: BitSeq.init(1))

    (
      await repo.putOverlayMetadata(
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
      await repo.putOverlayMetadata(
        treeCid,
        status = meta2.status.some,
        blocks = meta2.blocks,
        expiry = meta2.expiry,
      )
    ).tryGet()

    let got = (await repo.getOverlayMetadata(treeCid)).tryGet()
    check got.status == meta2.status
    check got.expiry == meta2.expiry
    check got.blocks == meta2.blocks

  test "Should delete overlay metadata":
    let treeCid = Cid.example
    let meta =
      OverlayMetadata(status: Completed, expiry: now + 10, blocks: BitSeq.init(0))

    (
      await repo.putOverlayMetadata(
        treeCid, status = meta.status.some, blocks = meta.blocks, expiry = meta.expiry
      )
    ).tryGet()
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
      await repo.putOverlayMetadata(
        treeCid = treeCid, status = Storing.some, blocks = blocks
      )
    ).tryGet()

    let meta = (await repo.getOverlayMetadata(treeCid)).tryGet()
    check meta.expiry == now + DefaultOverlayTtl

  test "Should create unique tmp overlays":
    let tmpCid1 = (await repo.createTmpOverlay()).tryGet()
    let tmpCid2 = (await repo.createTmpOverlay()).tryGet()

    check tmpCid1 != tmpCid2

  test "Should create tmp overlay with storing status":
    let tmpCid = (await repo.createTmpOverlay()).tryGet()
    let meta = (await repo.getOverlayMetadata(tmpCid)).tryGet()

    check meta.status == Storing

  test "Should set tmp overlay expiry from clock and ttl":
    let tmpCid = (await repo.createTmpOverlay()).tryGet()
    let meta = (await repo.getOverlayMetadata(tmpCid)).tryGet()

    check meta.expiry == now + DefaultOverlayTtl

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

    for (cid, status) in [(cid1, Completed), (cid2, Storing), (cid3, Failure)]:
      (
        await repo.putOverlayMetadata(
          treeCid = cid, status = status.some, blocks = BitSeq.init(1)
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

    for (cid, status) in [(cid1, Completed), (cid2, Storing), (cid3, Completed)]:
      (
        await repo.putOverlayMetadata(
          treeCid = cid, status = status.some, blocks = BitSeq.init(1)
        )
      ).tryGet()

    let iter = (await repo.listOverlaysInState(Completed)).tryGet()
    let cids = (await utils.collect(iter)).tryGet()

    check cids.len == 2
    check cids.anyIt(it == cid1)
    check cids.anyIt(it == cid3)
    check cids.allIt(it != cid2)

  test "Should return empty list when state has no matches":
    let cid = createTestBlock(41).cid

    (
      await repo.putOverlayMetadata(
        treeCid = cid, status = Completed.some, blocks = BitSeq.init(1)
      )
    ).tryGet()

    let iter = (await repo.listOverlaysInState(Deleting)).tryGet()
    let cids = (await utils.collect(iter)).tryGet()

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
        await repo.putOverlayMetadata(
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
        await repo.putOverlayMetadata(
          treeCid = cid, status = Completed.some, blocks = BitSeq.init(1)
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
      await repo.putOverlayMetadata(
        treeCid = treeCid1, status = Completed.some, blocks = BitSeq.init(2)
      )
    ).tryGet()

    (
      await repo.putOverlayMetadata(
        treeCid = treeCid2, status = Completed.some, blocks = BitSeq.init(2)
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
      await repo.putOverlayMetadata(
        treeCid = treeCid, status = Storing.some, blocks = BitSeq.init(0)
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

    check realOverlay.status == Storing
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

suite "withOverlay proc":
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

  test "Should create overlay before running body":
    let treeCid = Cid.example
    var statusDuringBody = Failure

    let res = await withOverlay(
      repo,
      treeCid,
      status = Storing.some,
      body = proc(): Future[?!void] {.closure, async: (raises: [CancelledError]).} =
        let meta = ?await repo.getOverlayMetadata(treeCid)
        statusDuringBody = meta.status
        success(),
    )

    check res.isOk
    check statusDuringBody == Storing

    let meta = (await repo.getOverlayMetadata(treeCid)).tryGet()
    check meta.status == Completed

  test "Should set completed state on async body success":
    let treeCid = Cid.example

    let res = await withOverlay(
      repo,
      treeCid,
      status = Storing.some,
      body = proc(): Future[?!void] {.closure, async: (raises: [CancelledError]).} =
        success(),
    )

    check res.isOk

    let meta = (await repo.getOverlayMetadata(treeCid)).tryGet()
    check meta.status == Completed

  test "Should set failure state on async body failure":
    let treeCid = Cid.example

    let res = await withOverlay(
      repo,
      treeCid,
      status = Storing.some,
      body = proc(): Future[?!void] {.closure, async: (raises: [CancelledError]).} =
        failure(newException(ValueError, "body failed")),
    )

    check res.isErr
    check res.error of ValueError

    let meta = (await repo.getOverlayMetadata(treeCid)).tryGet()
    check meta.status == Failure

  test "Should preserve typed body result":
    let treeCid = Cid.example

    let res = await withOverlay(
      repo,
      treeCid,
      status = Storing.some,
      body = proc(): Future[?!int] {.closure, async: (raises: [CancelledError]).} =
        success(42),
    )

    check res.isOk
    check res.get == 42

    let meta = (await repo.getOverlayMetadata(treeCid)).tryGet()
    check meta.status == Completed

  test "Should use custom expiry for final overlay metadata":
    let
      treeCid = Cid.example
      customExpiry: SecondsSince1970 = 500

    let res = await withOverlay(
      repo,
      treeCid,
      expiry = customExpiry,
      body = proc(): Future[?!void] {.closure, async: (raises: [CancelledError]).} =
        success(),
    )

    check res.isOk

    let meta = (await repo.getOverlayMetadata(treeCid)).tryGet()
    check meta.status == Completed
    check meta.expiry == customExpiry

  test "Should keep initial status when body is cancelled":
    let treeCid = Cid.example
    var bodyStarted = newFuture[void]("withOverlay.cancel.started")

    let op = withOverlay(
      repo,
      treeCid,
      status = Repairing.some,
      body = proc(): Future[?!void] {.closure, async: (raises: [CancelledError]).} =
        if not bodyStarted.finished:
          bodyStarted.complete()
        await sleepAsync(10.seconds)
        success(),
    )

    await bodyStarted.wait(500.millis)
    await op.cancelAndWait()

    try:
      discard await op
      check false
    except CatchableError as exc:
      check exc of CancelledError

    let meta = (await repo.getOverlayMetadata(treeCid)).tryGet()
    check meta.status == Repairing

  test "Should retain written leaf metadata when body is cancelled":
    let
      blk = createTestBlock(132)
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()
    var writeDone = newFuture[void]("withOverlay.cancel.writeDone")

    let op = withOverlay(
      repo,
      treeCid,
      status = Storing.some,
      body = proc(): Future[?!void] {.closure, async: (raises: [CancelledError]).} =
        ?await repo.putLeafsAndBlocks(treeCid, @[(blk, 0.Natural, proof)])
        if not writeDone.finished:
          writeDone.complete()
        await sleepAsync(10.seconds)
        success(),
    )

    await writeDone.wait(500.millis)
    await op.cancelAndWait()

    try:
      discard await op
      check false
    except CatchableError as exc:
      check exc of CancelledError

    let
      meta = (await repo.getOverlayMetadata(treeCid)).tryGet()
      leaf = (await repo.getLeafMetadata(treeCid, 0.Natural)).tryGet()
    check meta.status == Storing
    check leaf.blkCid == blk.cid

suite "withTmpOverlay proc":
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

  test "Should create tmp overlay before running body":
    let realTreeCid = Cid.example
    var statusDuringBody = Failure

    let res = await withTmpOverlay(
      repo,
      body = proc(
          tmpCid: Cid
      ): Future[?!Cid] {.closure, async: (raises: [CancelledError]).} =
        let tmpMeta = ?await repo.getOverlayMetadata(tmpCid)
        statusDuringBody = tmpMeta.status
        success(realTreeCid),
    )

    check res.isOk
    check res.get == realTreeCid
    check statusDuringBody == Storing

    let realMeta = (await repo.getOverlayMetadata(realTreeCid)).tryGet()
    check realMeta.status == Completed

  test "Should finalize tmp overlay and move leaves to real tree":
    let
      blk = createTestBlock(130)
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      realTreeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()
    var capturedTmpCid: Cid

    let res = await withTmpOverlay(
      repo,
      body = proc(
          tmpCid: Cid
      ): Future[?!Cid] {.closure, async: (raises: [CancelledError]).} =
        capturedTmpCid = tmpCid
        ?await repo.putLeafsAndBlocks(tmpCid, @[(blk, 0.Natural, proof)])
        success(realTreeCid),
    )

    check res.isOk
    check res.get == realTreeCid

    let leaf = (await repo.getLeafMetadata(realTreeCid, 0.Natural)).tryGet()
    check leaf.blkCid == blk.cid

    let tmpMetaRes = await repo.getOverlayMetadata(capturedTmpCid)
    check tmpMetaRes.isErr
    check tmpMetaRes.error() of KVStoreKeyNotFound

    let realMeta = (await repo.getOverlayMetadata(realTreeCid)).tryGet()
    check realMeta.status == Completed

  test "Should drop tmp overlay metadata on body failure":
    var capturedTmpCid: Cid

    let res = await withTmpOverlay(
      repo,
      body = proc(
          tmpCid: Cid
      ): Future[?!Cid] {.closure, async: (raises: [CancelledError]).} =
        capturedTmpCid = tmpCid
        Cid.failure("encode failed"),
    )

    check res.isErr
    check "encode failed" in res.error.msg

    let tmpMetaRes = await repo.getOverlayMetadata(capturedTmpCid)
    check tmpMetaRes.isErr
    check tmpMetaRes.error() of KVStoreKeyNotFound

  test "Should drop tmp overlay and cleanup stored leafs on body failure":
    let
      blk = createTestBlock(131)
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      proof = tree.getProof(0).tryGet()
    var capturedTmpCid: Cid

    let res = await withTmpOverlay(
      repo,
      body = proc(
          tmpCid: Cid
      ): Future[?!Cid] {.closure, async: (raises: [CancelledError]).} =
        capturedTmpCid = tmpCid
        ?await repo.putLeafsAndBlocks(tmpCid, @[(blk, 0.Natural, proof)])
        Cid.failure("encode failed after storing"),
    )

    check res.isErr
    check "encode failed after storing" in res.error.msg

    let tmpMetaRes = await repo.getOverlayMetadata(capturedTmpCid)
    check tmpMetaRes.isErr
    check tmpMetaRes.error() of KVStoreKeyNotFound

    let tmpLeafRes = await repo.getLeafMetadata(capturedTmpCid, 0.Natural)
    check tmpLeafRes.isErr
    check tmpLeafRes.error() of BlockNotFoundError

  test "Should drop tmp overlay metadata when body is cancelled":
    let realTreeCid = Cid.example
    var
      capturedTmpCid: Cid
      bodyStarted = newFuture[void]("withTmpOverlay.cancel.started")

    let op = withTmpOverlay(
      repo,
      body = proc(
          tmpCid: Cid
      ): Future[?!Cid] {.closure, async: (raises: [CancelledError]).} =
        capturedTmpCid = tmpCid
        if not bodyStarted.finished:
          bodyStarted.complete()
        await sleepAsync(10.seconds)
        success(realTreeCid),
    )

    await bodyStarted.wait(500.millis)
    await op.cancelAndWait()

    try:
      discard await op
      check false
    except CatchableError as exc:
      check exc of CancelledError

    let tmpMetaRes = await repo.getOverlayMetadata(capturedTmpCid)
    check tmpMetaRes.isErr
    check tmpMetaRes.error() of KVStoreKeyNotFound

  test "Should cleanup tmp overlay leaf and block on body cancellation":
    let
      blk = createTestBlock(133)
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      proof = tree.getProof(0).tryGet()
    var
      capturedTmpCid: Cid
      writeDone = newFuture[void]("withTmpOverlay.cancel.writeDone")

    let op = withTmpOverlay(
      repo,
      body = proc(
          tmpCid: Cid
      ): Future[?!Cid] {.closure, async: (raises: [CancelledError]).} =
        capturedTmpCid = tmpCid
        ?await repo.putLeafsAndBlocks(tmpCid, @[(blk, 0.Natural, proof)])
        if not writeDone.finished:
          writeDone.complete()
        await sleepAsync(10.seconds)
        success(tmpCid),
    )

    await writeDone.wait(500.millis)
    await op.cancelAndWait()

    try:
      discard await op
      check false
    except CatchableError as exc:
      check exc of CancelledError

    let tmpMetaRes = await repo.getOverlayMetadata(capturedTmpCid)
    check tmpMetaRes.isErr
    check tmpMetaRes.error() of KVStoreKeyNotFound

    let tmpLeafRes = await repo.getLeafMetadata(capturedTmpCid, 0.Natural)
    check tmpLeafRes.isErr
    check tmpLeafRes.error() of BlockNotFoundError

    let blkRes = await repo.getBlock(blk.cid)
    check blkRes.isErr
    check blkRes.error() of BlockNotFoundError

suite "BitSeq optimization tests":
  ## Tests for BitSeq-based optimizations in overlay operations.
  ## Verifies that BitSeq is correctly maintained and used for fast-path rejection.
  ##
  var
    tp: Taskpool
    repoDs: KVStore
    metaDs: KVStore
    mockClock: MockClock
    repo: RepoStore

  let now: SecondsSince1970 = 1000

  setup:
    tp = Taskpool.new()
    repoDs = SQLiteKVStore.new(SqliteMemory, tp).tryGet()
    metaDs = SQLiteKVStore.new(SqliteMemory, tp).tryGet()
    mockClock = MockClock.new()
    mockClock.set(now)
    repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 10000'nb)

  teardown:
    (await repoDs.close()).tryGet
    (await metaDs.close()).tryGet
    tp.shutdown()

  test "hasBlock returns false when bit not set in BitSeq":
    let
      blk = createTestBlock(100)
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    (await repo.putOverlayMetadata(treeCid, status = Completed.some)).tryGet()

    let hasBlockRes = await repo.hasBlock(treeCid, 0.Natural)
    check hasBlockRes.tryGet() == false

  test "hasBlock returns true when bit set and block exists":
    let
      blk = createTestBlock(101)
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    (await repo.putOverlayMetadata(treeCid, status = Completed.some)).tryGet()
    (await repo.putLeafsAndBlocks(treeCid, @[(blk, 0.Natural, proof)])).tryGet()

    let hasBlockRes = await repo.hasBlock(treeCid, 0.Natural)
    check hasBlockRes.tryGet() == true

  test "hasBlock returns false for index beyond BitSeq length":
    let
      blk = createTestBlock(102)
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    (await repo.putOverlayMetadata(treeCid, status = Completed.some)).tryGet()
    (await repo.putLeafsAndBlocks(treeCid, @[(blk, 0.Natural, proof)])).tryGet()

    let hasBlockRes = await repo.hasBlock(treeCid, 10.Natural)
    check hasBlockRes.tryGet() == false

  test "BitSeq updated correctly after putLeafsAndBlocks":
    let
      blk1 = createTestBlock(103)
      blk2 = createTestBlock(104)
      (_, tree) = makeManifestAndTree(@[blk1, blk2]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof1 = tree.getProof(0).tryGet()
      proof2 = tree.getProof(1).tryGet()

    (await repo.putOverlayMetadata(treeCid, status = Completed.some)).tryGet()
    (await repo.putLeafsAndBlocks(treeCid, @[(blk1, 0.Natural, proof1)])).tryGet()

    let meta1 = (await repo.getOverlayMetadata(treeCid)).tryGet()
    check meta1.blocks.len >= 1
    check meta1.blocks[0] == true

    (await repo.putLeafsAndBlocks(treeCid, @[(blk2, 1.Natural, proof2)])).tryGet()

    let meta2 = (await repo.getOverlayMetadata(treeCid)).tryGet()
    check meta2.blocks.len >= 2
    check meta2.blocks[0] == true
    check meta2.blocks[1] == true

  test "BitSeq updated correctly after delLeafBlockMetadata":
    let
      blk1 = createTestBlock(105)
      blk2 = createTestBlock(106)
      (_, tree) = makeManifestAndTree(@[blk1, blk2]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof1 = tree.getProof(0).tryGet()
      proof2 = tree.getProof(1).tryGet()

    (await repo.putOverlayMetadata(treeCid, status = Completed.some)).tryGet()

    (
      await repo.putLeafsAndBlocks(
        treeCid, @[(blk1, 0.Natural, proof1), (blk2, 1.Natural, proof2)]
      )
    ).tryGet()

    let metaBefore = (await repo.getOverlayMetadata(treeCid)).tryGet()
    check metaBefore.blocks.len >= 2
    check metaBefore.blocks[0] == true
    check metaBefore.blocks[1] == true

    (await repo.delLeafBlockMetadata(treeCid, @[0.Natural])).tryGet()

    let metaAfter = (await repo.getOverlayMetadata(treeCid)).tryGet()
    check metaAfter.blocks.len >= 2
    check metaAfter.blocks[0] == false
    check metaAfter.blocks[1] == true

  test "BitSeq consistency verified after operations":
    let
      blk = createTestBlock(107)
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    (await repo.putOverlayMetadata(treeCid, status = Completed.some)).tryGet()
    (await repo.putLeafsAndBlocks(treeCid, @[(blk, 0.Natural, proof)])).tryGet()

    let inconsistencies = (await repo.verifyOverlayBitSeqConsistency(treeCid)).tryGet()
    check inconsistencies.len == 0

  test "BitSeq consistency verified after delete":
    let
      blk = createTestBlock(108)
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    (await repo.putOverlayMetadata(treeCid, status = Completed.some)).tryGet()
    (await repo.putLeafsAndBlocks(treeCid, @[(blk, 0.Natural, proof)])).tryGet()
    (await repo.delLeafBlockMetadata(treeCid, @[0.Natural])).tryGet()

    let inconsistencies = (await repo.verifyOverlayBitSeqConsistency(treeCid)).tryGet()
    check inconsistencies.len == 0

  test "Shared blocks across overlays maintain correct BitSeq":
    let
      shared = createTestBlock(200)
      (_, tree1) = makeManifestAndTree(@[shared]).tryGet()
      treeCid1 = tree1.rootCid.tryGet()
      proof1 = tree1.getProof(0).tryGet()

    (await repo.putOverlayMetadata(treeCid1, status = Completed.some)).tryGet()
    (await repo.putLeafsAndBlocks(treeCid1, @[(shared, 0.Natural, proof1)])).tryGet()

    let meta1 = (await repo.getOverlayMetadata(treeCid1)).tryGet()
    check meta1.blocks[0] == true

    let refCount = (await repo.blockRefCount(shared.cid)).tryGet()
    check refCount == 1.Natural

    (await repo.dropOverlay(treeCid1)).tryGet()

    let blkRes = await repo.getBlock(shared.cid)
    check blkRes.isErr

  test "Multiple sequential put/delete maintains BitSeq consistency":
    let
      blk1 = createTestBlock(109)
      blk2 = createTestBlock(110)
      blk3 = createTestBlock(111)
      (_, tree) = makeManifestAndTree(@[blk1, blk2, blk3]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof1 = tree.getProof(0).tryGet()
      proof2 = tree.getProof(1).tryGet()
      proof3 = tree.getProof(2).tryGet()

    (await repo.putOverlayMetadata(treeCid, status = Completed.some)).tryGet()

    (
      await repo.putLeafsAndBlocks(
        treeCid, @[(blk1, 0.Natural, proof1), (blk2, 1.Natural, proof2)]
      )
    ).tryGet()
    let inconsistencies1 = (await repo.verifyOverlayBitSeqConsistency(treeCid)).tryGet()
    check inconsistencies1.len == 0

    (await repo.delLeafBlockMetadata(treeCid, @[0.Natural])).tryGet()
    let inconsistencies2 = (await repo.verifyOverlayBitSeqConsistency(treeCid)).tryGet()
    check inconsistencies2.len == 0

    (await repo.putLeafsAndBlocks(treeCid, @[(blk3, 2.Natural, proof3)])).tryGet()
    let inconsistencies3 = (await repo.verifyOverlayBitSeqConsistency(treeCid)).tryGet()
    check inconsistencies3.len == 0

  test "hasBlock fast-path avoids store hit for non-existent index":
    let
      blk = createTestBlock(112)
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      treeCid = tree.rootCid.tryGet()

    (await repo.putOverlayMetadata(treeCid, status = Completed.some)).tryGet()

    let hasBlockRes = await repo.hasBlock(treeCid, 5.Natural)
    check hasBlockRes.tryGet() == false

    let leafRes = await repo.getLeafMetadata(treeCid, 5.Natural)
    check leafRes.isErr
    check leafRes.error() of BlockNotFoundError

  test "Stress: random put/delete maintains BitSeq consistency":
    const Iterations = 20
    const MaxBlocks = 10

    var
      blocks: seq[bt.Block]
      proofs: seq[ArchivistProof]
      treeCid: Cid

    for i in 0 ..< MaxBlocks:
      let blk = createTestBlock(200 + i)
      blocks.add(blk)

    let (_, tree) = makeManifestAndTree(blocks).tryGet()
    treeCid = tree.rootCid.tryGet()

    for i in 0 ..< MaxBlocks:
      proofs.add(tree.getProof(i).tryGet())

    (await repo.putOverlayMetadata(treeCid, status = Completed.some)).tryGet()

    var indicesAdded: HashSet[Natural]
    for iter in 0 ..< Iterations:
      let op = rand(1)
      case op
      of 0:
        let idx = rand(MaxBlocks - 1).Natural
        if idx notin indicesAdded:
          (await repo.putLeafsAndBlocks(treeCid, @[(blocks[idx], idx, proofs[idx])])).tryGet()
          indicesAdded.incl(idx)
      else:
        if indicesAdded.len > 0:
          let indicesSeq = indicesAdded.toSeq
          let randIdx = rand(indicesSeq.len - 1)
          let idx = indicesSeq[randIdx]
          (await repo.delLeafBlockMetadata(treeCid, @[idx])).tryGet()
          indicesAdded.excl(idx)

      let inconsistencies =
        (await repo.verifyOverlayBitSeqConsistency(treeCid)).tryGet()
      check inconsistencies.len == 0

  test "BitSeq preserved through finalizeOverlay (temp to real)":
    let
      blk1 = createTestBlock(300)
      blk2 = createTestBlock(301)
      (_, tree) = makeManifestAndTree(@[blk1, blk2]).tryGet()
      realTreeCid = tree.rootCid.tryGet()
      proof1 = tree.getProof(0).tryGet()
      proof2 = tree.getProof(1).tryGet()
    var capturedTmpCid: Cid

    let res = await withTmpOverlay(
      repo,
      body = proc(
          tmpCid: Cid
      ): Future[?!Cid] {.closure, async: (raises: [CancelledError]).} =
        capturedTmpCid = tmpCid
        ?await repo.putLeafsAndBlocks(
          tmpCid, @[(blk1, 0.Natural, proof1), (blk2, 1.Natural, proof2)]
        )
        success(realTreeCid),
    )

    check res.isOk

    # Bitmap should be correct on the real overlay after finalize
    let realMeta = (await repo.getOverlayMetadata(realTreeCid)).tryGet()
    check realMeta.blocks.len >= 2
    check realMeta.blocks[0] == true
    check realMeta.blocks[1] == true

    # Verify full consistency
    let inconsistencies =
      (await repo.verifyOverlayBitSeqConsistency(realTreeCid)).tryGet()
    check inconsistencies.len == 0

    # Tmp overlay should be gone
    let tmpMetaRes = await repo.getOverlayMetadata(capturedTmpCid)
    check tmpMetaRes.isErr

  test "BitSeq correct after re-insert of deleted block (resurrection)":
    let
      blk = createTestBlock(302)
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    (await repo.putOverlayMetadata(treeCid, status = Completed.some)).tryGet()

    # Insert
    (await repo.putLeafsAndBlocks(treeCid, @[(blk, 0.Natural, proof)])).tryGet()
    let meta1 = (await repo.getOverlayMetadata(treeCid)).tryGet()
    check meta1.blocks[0] == true

    # Delete
    (await repo.delLeafBlockMetadata(treeCid, @[0.Natural])).tryGet()
    let meta2 = (await repo.getOverlayMetadata(treeCid)).tryGet()
    check meta2.blocks[0] == false

    # Re-insert (resurrection)
    (await repo.putLeafsAndBlocks(treeCid, @[(blk, 0.Natural, proof)])).tryGet()
    let meta3 = (await repo.getOverlayMetadata(treeCid)).tryGet()
    check meta3.blocks[0] == true

    # Full consistency check
    let inconsistencies = (await repo.verifyOverlayBitSeqConsistency(treeCid)).tryGet()
    check inconsistencies.len == 0
