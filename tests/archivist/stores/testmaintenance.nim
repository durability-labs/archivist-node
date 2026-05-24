## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronos
import pkg/kvstore
import pkg/taskpools
import pkg/questionable
import pkg/questionable/results
import pkg/stew/byteutils
import pkg/stew/bitseqs

import pkg/libp2p/multicodec

import pkg/archivist/blocktype as bt
import pkg/archivist/merkletree
import pkg/archivist/stores
import pkg/archivist/utils/asyncbarrier

import ../../asynctest
import ../helpers/mocktimer
import ../helpers/mockclock
import ../helpers
import ../examples

import archivist/stores/maintenance

suite "BlockMaintainer":
  var
    tp: Taskpool
    repoDs: KVStore
    metaDs: KVStore
    mockClock: MockClock
    mockTimer: MockTimer
    repo: RepoStore
    maintainer: BlockMaintainer
    interval: Duration

  setup:
    tp = Taskpool.new()
    repoDs = SQLiteKVStore.new(SqliteMemory, tp).tryGet()
    metaDs = SQLiteKVStore.new(SqliteMemory, tp).tryGet()
    mockClock = MockClock.new()
    mockClock.set(100)
    repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 2000'nb)
    interval = 1.days
    mockTimer = MockTimer.new()
    maintainer =
      BlockMaintainer.new(repo, interval, timer = mockTimer, clock = mockClock)

  teardown:
    (await repoDs.close()).tryGet()
    (await metaDs.close()).tryGet()
    tp.shutdown()

  test "Start should start timer at provided interval":
    maintainer.start()
    check mockTimer.startCalled == 1
    check mockTimer.mockInterval == interval

  test "Stop should stop timer":
    await maintainer.stop()
    check mockTimer.stopCalled == 1

  test "Should not drop overlays that have not expired":
    let treeCid = Cid.example

    (await repo.putOverlay(treeCid, status = Completed.some, expiry = 200)).tryGet()

    maintainer.start()
    await mockTimer.invokeCallback()

    let meta = (await repo.getOverlay(treeCid)).tryGet()
    check meta.expiry == 200

  test "Should drop overlay that has expired":
    let treeCid = Cid.example

    (await repo.putOverlay(treeCid, status = Completed.some, expiry = 50)).tryGet()

    maintainer.start()
    await mockTimer.invokeCallback()

    let res = await repo.getOverlay(treeCid)
    check res.isErr

  test "Should drop only expired overlays":
    let
      cid1 = Cid
        .init(
          CIDv1,
          multiCodec("codex-manifest"),
          bt.Block.new("a".toBytes).tryGet().cid.mhash.tryGet(),
        )
        .tryGet()
      cid2 = Cid
        .init(
          CIDv1,
          multiCodec("codex-manifest"),
          bt.Block.new("b".toBytes).tryGet().cid.mhash.tryGet(),
        )
        .tryGet()
      cid3 = Cid
        .init(
          CIDv1,
          multiCodec("codex-manifest"),
          bt.Block.new("c".toBytes).tryGet().cid.mhash.tryGet(),
        )
        .tryGet()

    (await repo.putOverlay(cid1, status = Completed.some, expiry = 50)).tryGet()
    (await repo.putOverlay(cid2, status = Completed.some, expiry = 200)).tryGet()
    (await repo.putOverlay(cid3, status = Completed.some, expiry = 90)).tryGet()

    maintainer.start()
    await mockTimer.invokeCallback()

    # cid1 (expiry=50) and cid3 (expiry=90) expired, cid2 (expiry=200) retained
    check (await repo.getOverlay(cid1)).isErr
    check (await repo.getOverlay(cid2)).isOk
    check (await repo.getOverlay(cid3)).isErr

  test "Should not drop overlays with default TTL that have not expired":
    let treeCid = Cid.example
    # ZeroSeconds triggers default TTL: now() + overlayTtl

    (await repo.putOverlay(treeCid, status = Completed.some, expiry = 0)).tryGet()

    # Clock is still at 100, well before the default TTL expiry
    maintainer.start()
    await mockTimer.invokeCallback()

    let meta = (await repo.getOverlay(treeCid)).tryGet()
    check meta.expiry > 0

  test "Should drop overlay in Failure status":
    let treeCid = Cid.example

    (await repo.putOverlay(treeCid, status = Failure.some, expiry = 200)).tryGet()
    maintainer.start()

    await mockTimer.invokeCallback()
    check (await repo.getOverlay(treeCid)).isErr

  test "Should drop overlay left in Deleting status (crash leftover)":
    let treeCid = Cid.example

    (await repo.putOverlay(treeCid, status = Deleting.some, expiry = 200)).tryGet()

    maintainer.start()
    await mockTimer.invokeCallback()

    check (await repo.getOverlay(treeCid)).isErr

  test "Should handle concurrent dropOverlay on same treeCid":
    let treeCid = Cid.example

    (await repo.putOverlay(treeCid, status = Deleting.some, expiry = 200)).tryGet()

    # Simulate an in-flight put by entering the barrier
    repo.deletingLock.enter(treeCid)

    maintainer.start()
    # Timer callback calls dropOverlay, which waits for the in-flight writer
    # before deleting prefixes and metadata.
    let callbackFut = mockTimer.invokeCallback()
    await sleepAsync(10.millis)
    repo.deletingLock.leave(treeCid)
    await callbackFut

    # Overlay is gone after the simulated writer finishes.
    check (await repo.getOverlay(treeCid)).isErr

  test "Should drop expired Pending overlay":
    let treeCid = Cid.example

    (await repo.putOverlay(treeCid, status = Pending.some, expiry = 50)).tryGet()

    maintainer.start()
    await mockTimer.invokeCallback()

    check (await repo.getOverlay(treeCid)).isErr

  test "Should not drop non-expired Pending overlay":
    let treeCid = Cid.example

    (await repo.putOverlay(treeCid, status = Pending.some, expiry = 200)).tryGet()

    maintainer.start()
    await mockTimer.invokeCallback()

    check (await repo.getOverlay(treeCid)).isOk

  test "Should return quota to zero when dropping expired overlay with manifest":
    let
      blk = bt.Block.new("test-data-for-maintenance".toBytes).tryGet()
      (manifest, tree) = makeManifestAndTree(@[blk]).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    var blocks = BitSeq.init(1)
    blocks.setBit(0)

    (
      await repo.putOverlay(
        treeCid = treeCid, status = Completed.some, blocks = blocks, expiry = 50
      )
    ).tryGet()

    (await repo.putBlocks(treeCid, @[(blk, 0.Natural, proof.some)])).tryGet()
    discard (await repo.storeManifest(manifest)).tryGet()

    check repo.quotaUsedBytes > 0.NBytes
    check repo.totalBlocks > 0.Natural

    maintainer.start()
    await mockTimer.invokeCallback()

    check repo.quotaUsedBytes == 0.NBytes
    check repo.totalBlocks == 0.Natural

  test "Should cleanup protected and verifiable manifests via maintenance expiry":
    var blocks: seq[bt.Block]
    for i in 0 ..< 4:
      blocks.add(bt.Block.new(("block-data-" & $i & "-for-maint").toBytes).tryGet())

    let
      (baseManifest, tree) = makeManifestAndTree(blocks).tryGet()
      treeCid = tree.rootCid.tryGet()
      maxDataLen = 22 # length of each "block-data-X-for-maint" string
      protManifest = Manifest.new(
        manifest = baseManifest,
        treeCid = treeCid,
        datasetSize = NBytes(8 * maxDataLen),
        ecK = 2,
        ecM = 2,
      )

    var slotRoots: seq[Cid]
    for _ in 0 ..< 4:
      slotRoots.add(Cid.example)

    let verManifest = Manifest.new(protManifest, Cid.example, slotRoots).tryGet()

    # Create tree overlay with expiry in the past (clock is at 100)
    var bits = BitSeq.init(blocks.len)
    for i in 0 ..< blocks.len:
      bits.setBit(i)

    (
      await repo.putOverlay(
        treeCid = treeCid, status = Completed.some, blocks = bits, expiry = 50
      )
    ).tryGet()

    # Store data blocks
    var blkProofs: seq[(bt.Block, Natural, ?ArchivistProof)]
    for i, blk in blocks:
      blkProofs.add((blk, i.Natural, tree.getProof(i).tryGet().some))
    (await repo.putBlocks(treeCid, blkProofs)).tryGet()

    # Store protected manifest on tree overlay
    discard (await repo.storeManifest(protManifest)).tryGet()

    # Store verifiable manifest on slot overlays
    let verManifestBlk = (await repo.storeVerifiableManifest(verManifest)).tryGet()
    let verifiableManifestBytes = verManifestBlk.data.len.NBytes

    # Create slot overlays with expiry in the future (200 > 100)
    for slotRoot in slotRoots:
      (await repo.putOverlay(slotRoot, status = Completed.some, expiry = 200)).tryGet()

    check repo.quotaUsedBytes > 0.NBytes
    check repo.totalBlocks > 0.Natural

    # Fire maintenance: tree overlay (expiry=50) is expired -> drops it
    # Protected manifest deleted, data blocks deleted, verifiable manifest kept
    maintainer.start()
    await mockTimer.invokeCallback()

    # Slot overlays (expiry=200) still alive
    for slotRoot in slotRoots:
      check (await repo.getOverlay(slotRoot)).isOk

    # Verifiable manifest still exists (slot overlays alive)
    check (await repo.getBlock(verManifestBlk.cid)).isOk

    # Only the verifiable manifest block remains
    check repo.quotaUsedBytes == verifiableManifestBytes
    check repo.totalBlocks == 1.Natural

    # Advance clock past slot expiry
    mockClock.set(300)
    await mockTimer.invokeCallback()

    # All slot overlays dropped -> verifiable manifest deleted
    for slotRoot in slotRoots:
      check (await repo.getOverlay(slotRoot)).isErr

    check repo.quotaUsedBytes == 0.NBytes
    check repo.totalBlocks == 0.Natural
