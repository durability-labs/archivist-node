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
import pkg/libp2p/multicodec

import pkg/archivist/stores
import pkg/archivist/stores/repostore/operations
import pkg/archivist/stores/repostore/overlays/coders
import pkg/archivist/blocktype as bt
import pkg/archivist/clock
import pkg/archivist/utils
import pkg/archivist/archivisttypes

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

  (await repo.putOverlay(treeCid = treeCid, status = Completed.some, blocks = blocks)).tryGet()
  (await repo.putBlocks(treeCid, @[(blk, 0.Natural, proof)])).tryGet()
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

    (await repo.putOverlay(treeCid = treeCid, status = Storing.some, blocks = blocks)).tryGet()

    let meta = (await repo.getOverlay(treeCid)).tryGet()
    check meta.expiry == now + DefaultOverlayTtl

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
        await repo.putOverlay(
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
        await repo.putOverlay(
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
      await repo.putOverlay(
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
    let overlayResult = await repo.getOverlay(treeCid)

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
      await repo.putOverlay(
        treeCid = treeCid1, status = Completed.some, blocks = BitSeq.init(2)
      )
    ).tryGet()

    (
      await repo.putOverlay(
        treeCid = treeCid2, status = Completed.some, blocks = BitSeq.init(2)
      )
    ).tryGet()

    (await repo.putBlocks(treeCid1, @[(shared, 0.Natural, proof1)])).tryGet()
    (await repo.putBlocks(treeCid2, @[(shared, 1.Natural, proof2)])).tryGet()
    check (await repo.blockRefCount(shared.cid)).tryGet() == 2.Natural

    (await repo.dropOverlay(treeCid1)).tryGet()

    check (await repo.blockRefCount(shared.cid)).tryGet() == 1.Natural
    check (await repo.getBlock(shared.cid)).isOk
    check (await repo.getOverlay(treeCid1)).isErr

  test "Should drop empty overlay metadata":
    let treeCid = Cid.example

    (
      await repo.putOverlay(
        treeCid = treeCid, status = Storing.some, blocks = BitSeq.init(0)
      )
    ).tryGet()

    (await repo.dropOverlay(treeCid)).tryGet()

    let res = await repo.getOverlay(treeCid)
    check res.isErr
    check res.error() of KVStoreKeyNotFound

  test "Should finalize overlay by moving metadata and leaves":
    let
      blk = createTestBlock(124)
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      realTreeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()
      tmpCid = (await repo.createTmpOverlay()).tryGet()

    (await repo.putBlocks(tmpCid, @[(blk, 0.Natural, proof)])).tryGet()
    (await repo.finalizeOverlay(tmpCid, realTreeCid)).tryGet()

    let
      realOverlay = (await repo.getOverlay(realTreeCid)).tryGet()
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

    (await repo.putBlocks(tmpCid, @[(blk, 0.Natural, proof)])).tryGet()
    (await repo.finalizeOverlay(tmpCid, realTreeCid)).tryGet()

    let res = await repo.getOverlay(tmpCid)
    check res.isErr
    check res.error() of KVStoreKeyNotFound

  test "Should provide block and proof under new tree after finalize":
    let
      blk = createTestBlock(126)
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      realTreeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()
      tmpCid = (await repo.createTmpOverlay()).tryGet()

    (await repo.putBlocks(tmpCid, @[(blk, 0.Natural, proof)])).tryGet()
    (await repo.finalizeOverlay(tmpCid, realTreeCid)).tryGet()

    let (_, gotBlock, gotProof) =
      (await repo.getBlockAndProof(realTreeCid, 0.Natural)).tryGet()
    check gotBlock.cid == blk.cid
    check gotProof.index == proof.index
    check gotProof.nleaves == proof.nleaves

  test "finalizeOverlay succeeds when destination leaf exists (content-addressed idempotency)":
    # When destination already has the same data, finalizeOverlay returns success
    # because the content-addressed guarantee means we're done.
    # The tmp overlay is dropped cleanly.
    let
      blk = createTestBlock(127)
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      realTreeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()
      tmpCid = (await repo.createTmpOverlay()).tryGet()

    # Pre-populate destination with the SAME block at same index
    (await repo.putOverlay(realTreeCid, status = Storing.some)).tryGet()
    (await repo.putBlocks(realTreeCid, @[(blk, 0.Natural, proof)])).tryGet()

    # Put same data in tmp overlay
    (await repo.putBlocks(tmpCid, @[(blk, 0.Natural, proof)])).tryGet()

    # Finalize should succeed (idempotent operation)
    let res = await repo.finalizeOverlay(tmpCid, realTreeCid)
    check res.isOk

    # Tmp overlay should be gone (dropped cleanly)
    let tmpMetaRes = await repo.getOverlay(tmpCid)
    check tmpMetaRes.isErr

    # Destination should still have the data
    let realLeaf = (await repo.getLeafMetadata(realTreeCid, 0.Natural)).tryGet()
    check realLeaf.blkCid == blk.cid

  test "finalizeOverlay handles conflict with different data at same index":
    # When destination has different data, finalizeOverlay still succeeds
    # because it assumes content-addressed storage (same CID = same data).
    # The moveKeysAtomic detects the conflict and the code handles it.
    let
      blk = createTestBlock(128)
      existingBlk = createTestBlock(129)
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      realTreeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()
      tmpCid = (await repo.createTmpOverlay()).tryGet()

    # Pre-populate destination with a different block at same index
    (await repo.putOverlay(realTreeCid, status = Storing.some)).tryGet()
    let
      (_, existingTree) = makeManifestAndTree(@[existingBlk]).tryGet()
      existingProof = existingTree.getProof(0).tryGet()

    (await repo.putBlocks(realTreeCid, @[(existingBlk, 0.Natural, existingProof)])).tryGet()

    # Put different data in tmp overlay
    (await repo.putBlocks(tmpCid, @[(blk, 0.Natural, proof)])).tryGet()

    # Finalize should succeed (KVConflictError is caught and handled)
    let res = await repo.finalizeOverlay(tmpCid, realTreeCid)
    check res.isOk

    # Tmp overlay should be gone (dropped on conflict)
    let tmpMetaRes = await repo.getOverlay(tmpCid)
    check tmpMetaRes.isErr

    # Destination should be unchanged (original data preserved)
    let realLeaf = (await repo.getLeafMetadata(realTreeCid, 0.Natural)).tryGet()
    check realLeaf.blkCid == existingBlk.cid

  test "finalizeOverlay succeeds when destination metadata exists":
    let
      blk = createTestBlock(129)
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      realTreeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()
      tmpCid = (await repo.createTmpOverlay()).tryGet()

    # Create destination with metadata but no leaf data
    (await repo.putOverlay(realTreeCid, status = Completed.some)).tryGet()

    (await repo.putBlocks(tmpCid, @[(blk, 0.Natural, proof)])).tryGet()
    let res = await repo.finalizeOverlay(tmpCid, realTreeCid)

    # Should succeed since there's no conflicting leaf data
    # (metadata merge is handled by the overlay system)
    check res.isOk

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

    let res = await repo.withOverlay(
      treeCid,
      status = Storing.some,
      body = proc(): Future[?!void] {.closure, async: (raises: [CancelledError]).} =
        let meta = ?await repo.getOverlay(treeCid)
        statusDuringBody = meta.status
        success(),
    )

    check res.isOk
    check statusDuringBody == Storing

    let meta = (await repo.getOverlay(treeCid)).tryGet()
    check meta.status == Completed

  test "Should set completed state on async body success":
    let treeCid = Cid.example

    let res = await repo.withOverlay(
      treeCid,
      status = Storing.some,
      body = proc(): Future[?!void] {.closure, async: (raises: [CancelledError]).} =
        success(),
    )

    check res.isOk

    let meta = (await repo.getOverlay(treeCid)).tryGet()
    check meta.status == Completed

  test "Should set failure state on async body failure":
    let treeCid = Cid.example

    let res = await repo.withOverlay(
      treeCid,
      status = Storing.some,
      body = proc(): Future[?!void] {.closure, async: (raises: [CancelledError]).} =
        failure(newException(ValueError, "body failed")),
    )

    check res.isErr
    check res.error of ValueError

    let meta = (await repo.getOverlay(treeCid)).tryGet()
    check meta.status == Failure

  test "Should preserve typed body result":
    let treeCid = Cid.example

    let res = await repo.withOverlay(
      treeCid,
      status = Storing.some,
      body = proc(): Future[?!int] {.closure, async: (raises: [CancelledError]).} =
        success(42),
    )

    check res.isOk
    check res.get == 42

    let meta = (await repo.getOverlay(treeCid)).tryGet()
    check meta.status == Completed

  test "Should use custom expiry for final overlay metadata":
    let
      treeCid = Cid.example
      customExpiry: SecondsSince1970 = 500

    let res = await repo.withOverlay(
      treeCid,
      expiry = customExpiry,
      body = proc(): Future[?!void] {.closure, async: (raises: [CancelledError]).} =
        success(),
    )

    check res.isOk

    let meta = (await repo.getOverlay(treeCid)).tryGet()
    check meta.status == Completed
    check meta.expiry == customExpiry

  test "Should keep initial status when body is cancelled":
    let treeCid = Cid.example
    var bodyStarted = newFuture[void]("withOverlay.cancel.started")

    let op = repo.withOverlay(
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

    expect CancelledError:
      discard await op

    let meta = (await repo.getOverlay(treeCid)).tryGet()
    check meta.status == Repairing

  test "Should retain written leaf metadata when body is cancelled":
    let
      blk = createTestBlock(132)
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()
    var writeDone = newFuture[void]("withOverlay.cancel.writeDone")

    let op = repo.withOverlay(
      treeCid,
      status = Storing.some,
      body = proc(): Future[?!void] {.closure, async: (raises: [CancelledError]).} =
        ?await repo.putBlocks(treeCid, @[(blk, 0.Natural, proof)])
        if not writeDone.finished:
          writeDone.complete()
        await sleepAsync(10.seconds)
        success(),
    )

    await writeDone.wait(500.millis)
    await op.cancelAndWait()

    expect CancelledError:
      discard await op

    let
      meta = (await repo.getOverlay(treeCid)).tryGet()
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

    let res = await repo.withTmpOverlay(
      body = proc(
          tmpCid: Cid
      ): Future[?!Cid] {.closure, async: (raises: [CancelledError]).} =
        let tmpMeta = ?await repo.getOverlay(tmpCid)
        statusDuringBody = tmpMeta.status
        success(realTreeCid)
    )

    check res.isOk
    check res.get == realTreeCid
    check statusDuringBody == Storing

    let realMeta = (await repo.getOverlay(realTreeCid)).tryGet()
    check realMeta.status == Completed

  test "Should finalize tmp overlay and move leaves to real tree":
    let
      blk = createTestBlock(130)
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      realTreeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()
    var capturedTmpCid: Cid

    let res = await repo.withTmpOverlay(
      body = proc(
          tmpCid: Cid
      ): Future[?!Cid] {.closure, async: (raises: [CancelledError]).} =
        capturedTmpCid = tmpCid
        ?await repo.putBlocks(tmpCid, @[(blk, 0.Natural, proof)])
        success(realTreeCid)
    )

    check res.isOk
    check res.get == realTreeCid

    let leaf = (await repo.getLeafMetadata(realTreeCid, 0.Natural)).tryGet()
    check leaf.blkCid == blk.cid

    let tmpMetaRes = await repo.getOverlay(capturedTmpCid)
    check tmpMetaRes.isErr
    check tmpMetaRes.error() of KVStoreKeyNotFound

    let realMeta = (await repo.getOverlay(realTreeCid)).tryGet()
    check realMeta.status == Completed

  test "Should drop tmp overlay metadata on body failure":
    var capturedTmpCid: Cid

    let res = await repo.withTmpOverlay(
      body = proc(
          tmpCid: Cid
      ): Future[?!Cid] {.closure, async: (raises: [CancelledError]).} =
        capturedTmpCid = tmpCid
        Cid.failure("encode failed")
    )

    check res.isErr
    check "encode failed" in res.error.msg

    let tmpMetaRes = await repo.getOverlay(capturedTmpCid)
    check tmpMetaRes.isErr
    check tmpMetaRes.error() of KVStoreKeyNotFound

  test "Should drop tmp overlay and cleanup stored leafs on body failure":
    let
      blk = createTestBlock(131)
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      proof = tree.getProof(0).tryGet()
    var capturedTmpCid: Cid

    let res = await repo.withTmpOverlay(
      body = proc(
          tmpCid: Cid
      ): Future[?!Cid] {.closure, async: (raises: [CancelledError]).} =
        capturedTmpCid = tmpCid
        ?await repo.putBlocks(tmpCid, @[(blk, 0.Natural, proof)])
        Cid.failure("encode failed after storing")
    )

    check res.isErr
    check "encode failed after storing" in res.error.msg

    let tmpMetaRes = await repo.getOverlay(capturedTmpCid)
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

    let op = repo.withTmpOverlay(
      body = proc(
          tmpCid: Cid
      ): Future[?!Cid] {.closure, async: (raises: [CancelledError]).} =
        capturedTmpCid = tmpCid
        if not bodyStarted.finished:
          bodyStarted.complete()
        await sleepAsync(10.seconds)
        success(realTreeCid)
    )

    await bodyStarted.wait(500.millis)
    await op.cancelAndWait()

    expect CancelledError:
      discard await op

    let tmpMetaRes = await repo.getOverlay(capturedTmpCid)
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

    let op = repo.withTmpOverlay(
      body = proc(
          tmpCid: Cid
      ): Future[?!Cid] {.closure, async: (raises: [CancelledError]).} =
        capturedTmpCid = tmpCid
        ?await repo.putBlocks(tmpCid, @[(blk, 0.Natural, proof)])
        if not writeDone.finished:
          writeDone.complete()
        await sleepAsync(10.seconds)
        success(tmpCid)
    )

    await writeDone.wait(500.millis)
    await op.cancelAndWait()

    expect CancelledError:
      discard await op

    let tmpMetaRes = await repo.getOverlay(capturedTmpCid)
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

    (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

    let hasBlockRes = await repo.hasBlock(treeCid, 0.Natural)
    check hasBlockRes.tryGet() == false

  test "hasBlock returns true when bit set and block exists":
    let
      blk = createTestBlock(101)
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()
    (await repo.putBlocks(treeCid, @[(blk, 0.Natural, proof)])).tryGet()

    let hasBlockRes = await repo.hasBlock(treeCid, 0.Natural)
    check hasBlockRes.tryGet() == true

  test "hasBlock returns false for index beyond BitSeq length":
    let
      blk = createTestBlock(102)
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()
    (await repo.putBlocks(treeCid, @[(blk, 0.Natural, proof)])).tryGet()

    let hasBlockRes = await repo.hasBlock(treeCid, 10.Natural)
    check hasBlockRes.tryGet() == false

  test "BitSeq updated correctly after putBlocks":
    let
      blk1 = createTestBlock(103)
      blk2 = createTestBlock(104)
      (_, tree) = makeManifestAndTree(@[blk1, blk2]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof1 = tree.getProof(0).tryGet()
      proof2 = tree.getProof(1).tryGet()

    (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()
    (await repo.putBlocks(treeCid, @[(blk1, 0.Natural, proof1)])).tryGet()

    let meta1 = (await repo.getOverlay(treeCid)).tryGet()
    check meta1.blocks.len >= 1
    check meta1.blocks[0] == true

    (await repo.putBlocks(treeCid, @[(blk2, 1.Natural, proof2)])).tryGet()

    let meta2 = (await repo.getOverlay(treeCid)).tryGet()
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

    (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

    (
      await repo.putBlocks(
        treeCid, @[(blk1, 0.Natural, proof1), (blk2, 1.Natural, proof2)]
      )
    ).tryGet()

    let metaBefore = (await repo.getOverlay(treeCid)).tryGet()
    check metaBefore.blocks.len >= 2
    check metaBefore.blocks[0] == true
    check metaBefore.blocks[1] == true

    (await repo.delLeafBlockMetadata(treeCid, @[0.Natural])).tryGet()

    let metaAfter = (await repo.getOverlay(treeCid)).tryGet()
    check metaAfter.blocks.len >= 2
    check metaAfter.blocks[0] == false
    check metaAfter.blocks[1] == true

  test "BitSeq consistency verified after operations":
    let
      blk = createTestBlock(107)
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()
    (await repo.putBlocks(treeCid, @[(blk, 0.Natural, proof)])).tryGet()

    let inconsistencies = (await repo.verifyBlockBitState(treeCid)).tryGet()
    check inconsistencies.len == 0

  test "BitSeq consistency verified after delete":
    let
      blk = createTestBlock(108)
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()
    (await repo.putBlocks(treeCid, @[(blk, 0.Natural, proof)])).tryGet()
    (await repo.delLeafBlockMetadata(treeCid, @[0.Natural])).tryGet()

    let inconsistencies = (await repo.verifyBlockBitState(treeCid)).tryGet()
    check inconsistencies.len == 0

  test "Shared blocks across overlays maintain correct BitSeq":
    let
      shared = createTestBlock(200)
      (_, tree1) = makeManifestAndTree(@[shared]).tryGet()
      treeCid1 = tree1.rootCid.tryGet()
      proof1 = tree1.getProof(0).tryGet()

    (await repo.putOverlay(treeCid1, status = Completed.some)).tryGet()
    (await repo.putBlocks(treeCid1, @[(shared, 0.Natural, proof1)])).tryGet()

    let meta1 = (await repo.getOverlay(treeCid1)).tryGet()
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

    (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

    (
      await repo.putBlocks(
        treeCid, @[(blk1, 0.Natural, proof1), (blk2, 1.Natural, proof2)]
      )
    ).tryGet()
    let inconsistencies1 = (await repo.verifyBlockBitState(treeCid)).tryGet()
    check inconsistencies1.len == 0

    (await repo.delLeafBlockMetadata(treeCid, @[0.Natural])).tryGet()
    let inconsistencies2 = (await repo.verifyBlockBitState(treeCid)).tryGet()
    check inconsistencies2.len == 0

    (await repo.putBlocks(treeCid, @[(blk3, 2.Natural, proof3)])).tryGet()
    let inconsistencies3 = (await repo.verifyBlockBitState(treeCid)).tryGet()
    check inconsistencies3.len == 0

  test "hasBlock fast-path avoids store hit for non-existent index":
    let
      blk = createTestBlock(112)
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      treeCid = tree.rootCid.tryGet()

    (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

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

    (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

    var indicesAdded: HashSet[Natural]
    for iter in 0 ..< Iterations:
      let op = rand(1)
      case op
      of 0:
        let idx = rand(MaxBlocks - 1).Natural
        if idx notin indicesAdded:
          (await repo.putBlocks(treeCid, @[(blocks[idx], idx, proofs[idx])])).tryGet()
          indicesAdded.incl(idx)
      else:
        if indicesAdded.len > 0:
          let indicesSeq = indicesAdded.toSeq
          let randIdx = rand(indicesSeq.len - 1)
          let idx = indicesSeq[randIdx]
          (await repo.delLeafBlockMetadata(treeCid, @[idx])).tryGet()
          indicesAdded.excl(idx)

      let inconsistencies = (await repo.verifyBlockBitState(treeCid)).tryGet()
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

    let res = await repo.withTmpOverlay(
      body = proc(
          tmpCid: Cid
      ): Future[?!Cid] {.closure, async: (raises: [CancelledError]).} =
        capturedTmpCid = tmpCid
        ?await repo.putBlocks(
          tmpCid, @[(blk1, 0.Natural, proof1), (blk2, 1.Natural, proof2)]
        )
        success(realTreeCid)
    )

    check res.isOk

    # Bitmap should be correct on the real overlay after finalize
    let realMeta = (await repo.getOverlay(realTreeCid)).tryGet()
    check realMeta.blocks.len >= 2
    check realMeta.blocks[0] == true
    check realMeta.blocks[1] == true

    # Verify full consistency
    let inconsistencies = (await repo.verifyBlockBitState(realTreeCid)).tryGet()
    check inconsistencies.len == 0

    # Tmp overlay should be gone
    let tmpMetaRes = await repo.getOverlay(capturedTmpCid)
    check tmpMetaRes.isErr

  test "BitSeq correct after re-insert of deleted block (resurrection)":
    let
      blk = createTestBlock(302)
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

    # Insert
    (await repo.putBlocks(treeCid, @[(blk, 0.Natural, proof)])).tryGet()
    let meta1 = (await repo.getOverlay(treeCid)).tryGet()
    check meta1.blocks[0] == true

    # Delete
    (await repo.delLeafBlockMetadata(treeCid, @[0.Natural])).tryGet()
    let meta2 = (await repo.getOverlay(treeCid)).tryGet()
    check meta2.blocks[0] == false

    # Re-insert (resurrection)
    (await repo.putBlocks(treeCid, @[(blk, 0.Natural, proof)])).tryGet()
    let meta3 = (await repo.getOverlay(treeCid)).tryGet()
    check meta3.blocks[0] == true

    # Full consistency check
    let inconsistencies = (await repo.verifyBlockBitState(treeCid)).tryGet()
    check inconsistencies.len == 0

suite "Cell-aware leaf metadata":
  ## Tests for slot proof cell leaves that store cellCid separately from blkCid.
  ## This ensures refcounts track real blocks, not Poseidon2 cell digests.
  ##
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
    repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 10000'nb)

  teardown:
    (await repoDs.close()).tryGet
    (await metaDs.close()).tryGet
    tp.shutdown()

  test "putCidsAndProofs stores cell leaf with correct blkCid for refcount":
    let
      blk = createTestBlock(400)
      # Create a different CID for the cell (simulating Poseidon2 digest)
      cellCid = bt.Block.new("cell data".toBytes).tryGet().cid
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

    # Store using 4-tuple (index, cellCid, blkCid, proof)
    (await repo.putCellCidsAndProofs(treeCid, @[(0.Natural, cellCid, blk.cid, proof)])).tryGet()

    let
      leaf = (await repo.getLeafMetadata(treeCid, 0.Natural)).tryGet()
      blkRefCount = (await repo.blockRefCount(blk.cid)).tryGet()

    check:
      leaf.isCell == true
      leaf.cellCid == cellCid
      leaf.blkCid == blk.cid # blkCid points to real block
      blkRefCount == 1 # Refcount on real block, not cellCid

  test "putCidsAndProofs increments refcount only on blkCid, not cellCid":
    let
      blk1 = createTestBlock(401)
      blk2 = createTestBlock(402)
      cellCid1 = bt.Block.new("cell1".toBytes).tryGet().cid
      cellCid2 = bt.Block.new("cell2".toBytes).tryGet().cid
      (_, tree) = makeManifestAndTree(@[blk1, blk2]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof1 = tree.getProof(0).tryGet()
      proof2 = tree.getProof(1).tryGet()

    (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

    # Store two cell leaves referencing different blocks

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
      blkRefCount1 = (await repo.blockRefCount(blk1.cid)).tryGet()
      blkRefCount2 = (await repo.blockRefCount(blk2.cid)).tryGet()
      # Cell CIDs should NOT have block metadata (no refcount entries)
      cellRefCountRes1 = await repo.blockRefCount(cellCid1)
      cellRefCountRes2 = await repo.blockRefCount(cellCid2)

    check:
      blkRefCount1 == 1
      blkRefCount2 == 1
      cellRefCountRes1.isErr # No metadata for cell CIDs
      cellRefCountRes2.isErr

  test "delLeafBlockMetadata decrements refcount on blkCid for cell leaves":
    let
      blk1 = createTestBlock(403)
      blk2 = createTestBlock(404)
        # Second block (not used for refcount, just tree structure)
      cellCid1 = bt.Block.new("cell data".toBytes).tryGet().cid
      cellCid2 = bt.Block.new("cell2".toBytes).tryGet().cid
      (_, tree) = makeManifestAndTree(@[blk1, blk2]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof1 = tree.getProof(0).tryGet()
      proof2 = tree.getProof(1).tryGet()

    (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()
    # Store two cell leaves referencing the same block (blk1)

    (
      await repo.putCellCidsAndProofs(
        treeCid,
        @[
          (0.Natural, cellCid1, blk1.cid, proof1),
          (1.Natural, cellCid2, blk1.cid, proof2),
        ],
      )
    ).tryGet()

    let refCountBefore = (await repo.blockRefCount(blk1.cid)).tryGet()
    check refCountBefore == 2

    # Delete one cell leaf
    (await repo.delLeafBlockMetadata(treeCid, @[0.Natural])).tryGet()

    let refCountAfter = (await repo.blockRefCount(blk1.cid)).tryGet()
    check refCountAfter == 1

  test "Multiple cell leaves referencing same block increment refcount correctly":
    let
      blk = createTestBlock(404)
      cellCid1 = bt.Block.new("cell1".toBytes).tryGet().cid
      cellCid2 = bt.Block.new("cell2".toBytes).tryGet().cid
      blk2 = createTestBlock(405)
      (_, tree) = makeManifestAndTree(@[blk, blk2]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof1 = tree.getProof(0).tryGet()
      proof2 = tree.getProof(1).tryGet()

    (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

    # Two cell leaves reference the same block (blk) at different indices

    (
      await repo.putCellCidsAndProofs(
        treeCid,
        @[
          (0.Natural, cellCid1, blk.cid, proof1), (1.Natural, cellCid2, blk.cid, proof2)
        ],
      )
    ).tryGet()

    let refCount = (await repo.blockRefCount(blk.cid)).tryGet()
    check refCount == 2

  test "Cell leaves and regular leaves can coexist on same overlay":
    let
      blk1 = createTestBlock(410)
      blk2 = createTestBlock(411)
      cellCid = bt.Block.new("cell".toBytes).tryGet().cid
      (_, tree) = makeManifestAndTree(@[blk1, blk2]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof1 = tree.getProof(0).tryGet()
      proof2 = tree.getProof(1).tryGet()

    (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

    # Store a cell leaf using 4-tuple API

    (
      await repo.putCellCidsAndProofs(
        treeCid, @[(0.Natural, cellCid, blk1.cid, proof1)]
      )
    ).tryGet()
    # Store a regular leaf using 3-tuple API (no cellCid)
    (await repo.putCidsAndProofs(treeCid, @[(1.Natural, blk2.cid, proof2)])).tryGet()

    let
      leaf1 = (await repo.getLeafMetadata(treeCid, 0.Natural)).tryGet()
      leaf2 = (await repo.getLeafMetadata(treeCid, 1.Natural)).tryGet()

    check:
      leaf1.isCell == true
      leaf1.cellCid == cellCid
      leaf1.blkCid == blk1.cid
      leaf2.isCell == false # Regular leaf (no cellCid)

suite "Slot overlay lifecycle":
  ## Tests for slot tree overlay creation and cell-aware metadata storage.
  ## Verifies that slot proof trees store correct cell metadata and refcounts.
  ##
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
    repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 10000'nb)

  teardown:
    (await repoDs.close()).tryGet
    (await metaDs.close()).tryGet
    tp.shutdown()

  test "Slot tree overlay stores cell CIDs with correct blkCid refcount":
    let
      blk1 = createTestBlock(600)
      blk2 = createTestBlock(601)
      # Create distinct cell CIDs (simulating Poseidon2 digests)
      cellCid1 = bt.Block.new("cell1".toBytes).tryGet().cid
      cellCid2 = bt.Block.new("cell2".toBytes).tryGet().cid
      (_, tree) = makeManifestAndTree(@[blk1, blk2]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof1 = tree.getProof(0).tryGet()
      proof2 = tree.getProof(1).tryGet()

    (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

    # Store slot proof items: (index, cellCid, blkCid, proof)

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
      refCount1 = (await repo.blockRefCount(blk1.cid)).tryGet()
      refCount2 = (await repo.blockRefCount(blk2.cid)).tryGet()

    check:
      # Cell metadata stored correctly
      leaf1.isCell == true
      leaf1.cellCid == cellCid1
      leaf1.blkCid == blk1.cid
      leaf2.isCell == true
      leaf2.cellCid == cellCid2
      leaf2.blkCid == blk2.cid
      # Refcounts on real blocks, not cell CIDs
      refCount1 == 1
      refCount2 == 1

  test "Multiple slots referencing same block increment refcount correctly":
    let
      blk = createTestBlock(610)
      cellCid1 = bt.Block.new("cell1".toBytes).tryGet().cid
      cellCid2 = bt.Block.new("cell2".toBytes).tryGet().cid
      blk2 = createTestBlock(611) # Second block for tree structure
      (_, tree) = makeManifestAndTree(@[blk, blk2]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof1 = tree.getProof(0).tryGet()
      proof2 = tree.getProof(1).tryGet()

    (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

    # Two cell entries reference the same block

    (
      await repo.putCellCidsAndProofs(
        treeCid,
        @[
          (0.Natural, cellCid1, blk.cid, proof1), (1.Natural, cellCid2, blk.cid, proof2)
        ],
      )
    ).tryGet()

    let refCount = (await repo.blockRefCount(blk.cid)).tryGet()
    check refCount == 2

suite "Empty blkCid (pad block) handling":
  ## Tests for handling empty blkCid in leaf metadata.
  ## This is used for pad blocks in slot trees where proofs need to be stored
  ## but there's no actual block to reference.

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
    repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 10000'nb)

  teardown:
    (await repoDs.close()).tryGet
    (await metaDs.close()).tryGet
    tp.shutdown()

  test "putCidsAndProofs with empty blkCid stores leaf but no block metadata":
    let
      blk = createTestBlock(700)
      cellCid = bt.Block.new("cell".toBytes).tryGet().cid
      emptyBlkCid = emptyCid(CIDv1, multiCodec("sha2-256"), BlockCodec).tryGet()
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

    # Store with empty blkCid (simulating a pad block)

    (
      await repo.putCellCidsAndProofs(
        treeCid, @[(0.Natural, cellCid, emptyBlkCid, proof)]
      )
    ).tryGet()

    # Leaf metadata should exist
    let leaf = (await repo.getLeafMetadata(treeCid, 0.Natural)).tryGet()
    check:
      leaf.isCell == true
      leaf.cellCid == cellCid
      leaf.blkCid == emptyBlkCid
      leaf.blkCid.isEmpty == true

    # Block metadata should NOT exist for empty CID
    let refCountRes = await repo.blockRefCount(emptyBlkCid)
    check refCountRes.isErr

  test "Multiple empty blkCid leaves don't corrupt refcount":
    let
      blk = createTestBlock(701)
      cellCid1 = bt.Block.new("cell1".toBytes).tryGet().cid
      cellCid2 = bt.Block.new("cell2".toBytes).tryGet().cid
      emptyBlkCid = emptyCid(CIDv1, multiCodec("sha2-256"), BlockCodec).tryGet()
      (_, tree) = makeManifestAndTree(@[blk, blk]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof1 = tree.getProof(0).tryGet()
      proof2 = tree.getProof(1).tryGet()

    (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

    # Store two leaves with empty blkCid

    (
      await repo.putCellCidsAndProofs(
        treeCid,
        @[
          (0.Natural, cellCid1, emptyBlkCid, proof1),
          (1.Natural, cellCid2, emptyBlkCid, proof2),
        ],
      )
    ).tryGet()

    # Both leaves should exist
    let
      leaf1 = (await repo.getLeafMetadata(treeCid, 0.Natural)).tryGet()
      leaf2 = (await repo.getLeafMetadata(treeCid, 1.Natural)).tryGet()

    check:
      leaf1.blkCid.isEmpty == true
      leaf2.blkCid.isEmpty == true

    # No block metadata should exist for empty CID
    let refCountRes = await repo.blockRefCount(emptyBlkCid)
    check refCountRes.isErr

  test "Mix of empty and real blkCid works correctly":
    let
      realBlk = createTestBlock(702)
      cellCid1 = bt.Block.new("cell1".toBytes).tryGet().cid
      cellCid2 = bt.Block.new("cell2".toBytes).tryGet().cid
      emptyBlkCid = emptyCid(CIDv1, multiCodec("sha2-256"), BlockCodec).tryGet()
      (_, tree) = makeManifestAndTree(@[realBlk, realBlk]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof1 = tree.getProof(0).tryGet()
      proof2 = tree.getProof(1).tryGet()

    (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

    # Store one with real blkCid, one with empty

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
      realRefCount = (await repo.blockRefCount(realBlk.cid)).tryGet()

    check:
      leaf1.blkCid == realBlk.cid
      leaf1.blkCid.isEmpty == false
      leaf2.blkCid.isEmpty == true
      # Only real block has refcount
      realRefCount == 1

  test "Delete leaf with empty blkCid works without error":
    let
      blk = createTestBlock(703)
      cellCid = bt.Block.new("cell".toBytes).tryGet().cid
      emptyBlkCid = emptyCid(CIDv1, multiCodec("sha2-256"), BlockCodec).tryGet()
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

    # Store with empty blkCid

    (
      await repo.putCellCidsAndProofs(
        treeCid, @[(0.Natural, cellCid, emptyBlkCid, proof)]
      )
    ).tryGet()

    # Verify leaf exists before delete
    let leafBefore = (await repo.getLeafMetadata(treeCid, 0.Natural)).tryGet()
    check leafBefore.blkCid.isEmpty == true

    # Delete should succeed even with empty blkCid (no block metadata to decrement)
    (await repo.delLeafBlockMetadata(treeCid, @[0.Natural])).tryGet()

    # Leaf should be fully deleted (delLeafBlockMetadata removes it)
    let leafRes = await repo.getLeafMetadata(treeCid, 0.Natural)
    check leafRes.isErr

  test "Delete mix of empty and real blkCid decrements only real block":
    let
      realBlk = createTestBlock(704)
      cellCid1 = bt.Block.new("cell1".toBytes).tryGet().cid
      cellCid2 = bt.Block.new("cell2".toBytes).tryGet().cid
      emptyBlkCid = emptyCid(CIDv1, multiCodec("sha2-256"), BlockCodec).tryGet()
      (_, tree) = makeManifestAndTree(@[realBlk, realBlk]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof1 = tree.getProof(0).tryGet()
      proof2 = tree.getProof(1).tryGet()

    (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

    # Store one real, one empty

    (
      await repo.putCellCidsAndProofs(
        treeCid,
        @[
          (0.Natural, cellCid1, realBlk.cid, proof1),
          (1.Natural, cellCid2, emptyBlkCid, proof2),
        ],
      )
    ).tryGet()

    let refCountBefore = (await repo.blockRefCount(realBlk.cid)).tryGet()
    check refCountBefore == 1

    # Delete both - should only decrement real block, no error for empty blkCid
    (await repo.delLeafBlockMetadata(treeCid, @[0.Natural, 1.Natural])).tryGet()

    # Block metadata is deleted when refCount hits 0
    let refCountAfter = await repo.blockRefCount(realBlk.cid)
    check refCountAfter.isErr # Block metadata deleted

  test "putBlocks with empty blkCid in proof context works":
    # Test the regular (non-cell) leaf path with empty blkCid
    let
      blk = createTestBlock(705)
      emptyBlkCid = emptyCid(CIDv1, multiCodec("sha2-256"), BlockCodec).tryGet()
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

    # Create a block with empty CID
    let emptyBlk = bt.Block.new(newSeq[byte](0)).tryGet()
    check emptyBlk.cid.isEmpty == true

    # Store with the empty block
    (await repo.putBlocks(treeCid, @[(emptyBlk, 0.Natural, proof)])).tryGet()

    # Leaf should exist with empty blkCid
    let leaf = (await repo.getLeafMetadata(treeCid, 0.Natural)).tryGet()
    check:
      leaf.blkCid.isEmpty == true
      leaf.isCell == false

suite "Concurrent overlay bitset updates":
  ## Tests for concurrent put/delete operations on the same overlay.
  ## Verifies bitmap consistency under race conditions and CAS retry behavior.

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

    # Run concurrent put operations
    let
      put1Future = repo.putBlocks(treeCid, @[(blk1, 0.Natural, proof1)])
      put2Future = repo.putBlocks(treeCid, @[(blk2, 1.Natural, proof2)])
      put3Future = repo.putBlocks(treeCid, @[(blk3, 2.Natural, proof3)])

    await allFutures(@[put1Future, put2Future, put3Future])

    # All operations should succeed - check by re-awaiting
    check (await put1Future).isOk
    check (await put2Future).isOk
    check (await put3Future).isOk

    # Verify all blocks are present with correct bitset
    let meta = (await repo.getOverlay(treeCid)).tryGet()
    check:
      meta.blocks[0] == true
      meta.blocks[1] == true
      meta.blocks[2] == true

    # Verify consistency
    let inconsistencies = (await repo.verifyBlockBitState(treeCid)).tryGet()
    check inconsistencies.len == 0

  test "Concurrent put and delete operations maintain consistency":
    let
      blk1 = createTestBlock(810)
      blk2 = createTestBlock(811)
      (_, tree) = makeManifestAndTree(@[blk1, blk2]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof1 = tree.getProof(0).tryGet()
      proof2 = tree.getProof(1).tryGet()

    (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

    # Put both blocks first

    (
      await repo.putBlocks(
        treeCid, @[(blk1, 0.Natural, proof1), (blk2, 1.Natural, proof2)]
      )
    ).tryGet()

    let metaBefore = (await repo.getOverlay(treeCid)).tryGet()
    check:
      metaBefore.blocks[0] == true
      metaBefore.blocks[1] == true

    # Run concurrent operations: delete index 0 while putting index 2
    let
      blk3 = createTestBlock(812)
      proof3 = tree.getProof(0).tryGet() # reuse proof for simplicity
      delOp = repo.delLeafBlockMetadata(treeCid, @[0.Natural])
      putOp = repo.putBlocks(treeCid, @[(blk3, 0.Natural, proof3)])

    await allFutures(@[delOp, putOp])

    # One of the operations should succeed
    # The key is that BitSeq remains consistent
    let metaAfter = (await repo.getOverlay(treeCid)).tryGet()
    check metaAfter.blocks.len >= 1

    # Verify consistency
    let inconsistencies = (await repo.verifyBlockBitState(treeCid)).tryGet()
    check inconsistencies.len == 0

  test "Sequential put-delete-put maintains BitSeq consistency":
    let
      blk1 = createTestBlock(820)
      blk2 = createTestBlock(821)
      (_, tree) = makeManifestAndTree(@[blk1, blk2]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof1 = tree.getProof(0).tryGet()
      proof2 = tree.getProof(1).tryGet()

    (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

    # Put block at index 0
    (await repo.putBlocks(treeCid, @[(blk1, 0.Natural, proof1)])).tryGet()
    let meta1 = (await repo.getOverlay(treeCid)).tryGet()
    check meta1.blocks[0] == true

    # Delete block at index 0
    (await repo.delLeafBlockMetadata(treeCid, @[0.Natural])).tryGet()
    let meta2 = (await repo.getOverlay(treeCid)).tryGet()
    check meta2.blocks[0] == false

    # Re-put block at index 0
    (await repo.putBlocks(treeCid, @[(blk2, 0.Natural, proof1)])).tryGet()
    let meta3 = (await repo.getOverlay(treeCid)).tryGet()
    check meta3.blocks[0] == true

    # Verify consistency
    let inconsistencies = (await repo.verifyBlockBitState(treeCid)).tryGet()
    check inconsistencies.len == 0

  test "Multiple overlapping CAS operations eventually converge":
    let
      blk = createTestBlock(830)
      (_, tree) = makeManifestAndTree(@[blk]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

    # Run multiple rounds of concurrent put/delete
    for round in 0 ..< 5:
      let
        putOp = repo.putBlocks(treeCid, @[(blk, 0.Natural, proof)])
        delOp = repo.delLeafBlockMetadata(treeCid, @[0.Natural])

      # Execute concurrently
      await allFutures(@[putOp, delOp])

      # Verify consistency after each round
      let inconsistencies = (await repo.verifyBlockBitState(treeCid)).tryGet()
      check inconsistencies.len == 0

  test "CAS retry behavior works correctly":
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

    # Simulate CAS retry by doing multiple updates to same key
    for i in 0 ..< 3:
      let blk =
        if i == 0:
          blk1
        elif i == 1:
          blk2
        else:
          blk3
      let prf =
        if i == 0:
          proof1
        elif i == 1:
          proof2
        else:
          proof3

      (await repo.putBlocks(treeCid, @[(blk, 0.Natural, prf)])).tryGet()

      # Verify after each update
      let meta = (await repo.getOverlay(treeCid)).tryGet()
      check meta.blocks[0] == true

      let inconsistencies = (await repo.verifyBlockBitState(treeCid)).tryGet()
      check inconsistencies.len == 0

  test "Concurrent overlay metadata updates preserve latest values":
    let treeCid = Cid.example

    # Start multiple concurrent metadata updates
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

    # At least one should succeed
    check res1.isOk or res2.isOk

    # Get final state
    let meta = (await repo.getOverlay(treeCid)).tryGet()
    # Either Storing or Completed is valid - just verify it's one of them
    check meta.status in {Storing, Completed}

  test "Concurrent updates to different indices don't interfere":
    let
      blk1 = createTestBlock(850)
      blk2 = createTestBlock(851)
      blk3 = createTestBlock(852)
      blk4 = createTestBlock(853)
      (_, tree) = makeManifestAndTree(@[blk1, blk2, blk3, blk4]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof1 = tree.getProof(0).tryGet()
      proof2 = tree.getProof(1).tryGet()
      proof3 = tree.getProof(2).tryGet()
      proof4 = tree.getProof(3).tryGet()

    (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

    # Concurrent puts to different indices
    let
      put1Future = repo.putBlocks(treeCid, @[(blk1, 0.Natural, proof1)])
      put2Future = repo.putBlocks(treeCid, @[(blk2, 1.Natural, proof2)])
      put3Future = repo.putBlocks(treeCid, @[(blk3, 2.Natural, proof3)])
      put4Future = repo.putBlocks(treeCid, @[(blk4, 3.Natural, proof4)])

    await allFutures(@[put1Future, put2Future, put3Future, put4Future])

    # All should succeed
    check:
      (await put1Future).isOk
      (await put2Future).isOk
      (await put3Future).isOk
      (await put4Future).isOk

    # Verify all bits are set
    let meta = (await repo.getOverlay(treeCid)).tryGet()
    check:
      meta.blocks[0] == true
      meta.blocks[1] == true
      meta.blocks[2] == true
      meta.blocks[3] == true

    let inconsistencies = (await repo.verifyBlockBitState(treeCid)).tryGet()
    check inconsistencies.len == 0
