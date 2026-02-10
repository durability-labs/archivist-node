import std/os
import std/strutils
import std/sequtils

import pkg/questionable
import pkg/questionable/results

import pkg/chronos
import pkg/stew/byteutils
import pkg/stew/bitseqs
import pkg/kvstore
import pkg/taskpools

import pkg/archivist/chunker
import pkg/archivist/stores
import pkg/archivist/stores/repostore/operations
import pkg/archivist/blocktype as bt
import pkg/archivist/clock
import pkg/archivist/utils/safeasynciter
import pkg/archivist/merkletree/archivist

import ../../asynctest
import ../helpers
import ../helpers/mockclock
import ../examples
import ./commonstoretests

suite "Test RepoStore start/stop":
  var
    tp: Taskpool
    repoDs: KVStore
    metaDs: KVStore

  setup:
    tp = Taskpool.new()
    repoDs = SQLiteKVStore.new(SqliteMemory, tp).tryGet()
    metaDs = SQLiteKVStore.new(SqliteMemory, tp).tryGet()

  teardown:
    (await repoDs.close()).tryGet
    (await metaDs.close()).tryGet
    tp.shutdown()

  test "Should set started flag once started":
    let repo = RepoStore.new(repoDs, metaDs, quotaMaxBytes = 200'nb)
    await repo.start()
    check repo.started

  test "Should set started flag to false once stopped":
    let repo = RepoStore.new(repoDs, metaDs, quotaMaxBytes = 200'nb)
    await repo.start()
    await repo.stop()
    check not repo.started

  test "Should allow start to be called multiple times":
    let repo = RepoStore.new(repoDs, metaDs, quotaMaxBytes = 200'nb)
    await repo.start()
    await repo.start()
    check repo.started

  test "Should allow stop to be called multiple times":
    let repo = RepoStore.new(repoDs, metaDs, quotaMaxBytes = 200'nb)
    await repo.stop()
    await repo.stop()
    check not repo.started

suite "RepoStore":
  var
    path = currentSourcePath() # get this file's name
    basePath = "tests_data"
    basePathAbs = path.parentDir / basePath
    tp: Taskpool
    repoDs: KVStore
    metaDs: KVStore
    mockClock: MockClock
    repo: RepoStore

  let now: SecondsSince1970 = 123

  setup:
    # removeDir(basePathAbs)
    # require(not dirExists(basePathAbs))
    # createDir(basePathAbs)

    tp = Taskpool.new()
    repoDs = SQLiteKVStore.new(SqliteMemory, tp).tryGet()
    metaDs = SQLiteKVStore.new(SqliteMemory, tp).tryGet()
    mockClock = MockClock.new()
    mockClock.set(now)

    repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 200'nb)

  teardown:
    (await repoDs.close()).tryGet
    (await metaDs.close()).tryGet
    tp.shutdown()

    # removeDir(basePathAbs)
    # require(not dirExists(basePathAbs))

  proc createTestBlock(size: int): bt.Block =
    bt.Block.new('a'.repeat(size).toBytes).tryGet()

  proc putBlockWithOverlay(
      repo: RepoStore, blk: bt.Block
  ): Future[?!(Cid, Natural)] {.async.} =
    let (manifest, tree) = makeManifestAndTree(@[blk]).tryGet()
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

  test "Should handle duplicate CIDs in same putLeafsAndBlocks batch correctly":
    let blk = createTestBlock(100)

    # Build manifest/tree with same block at indices 0 and 1
    let (manifest, tree) = makeManifestAndTree(@[blk, blk]).tryGet()
    let treeCid = tree.rootCid.tryGet()

    # Create overlay
    var blocks = BitSeq.init(2)

    (
      await repo.createOrUpdateOverlay(
        treeCid = treeCid, status = OverlayStatus.Completed, blocks = blocks
      )
    ).tryGet()

    # Get initial counters
    let
      initialBytes = repo.quotaUsedBytes
      initialBlocks = repo.totalBlocks

      # Put same block at two indices
      proof0 = tree.getProof(0).tryGet()
      proof1 = tree.getProof(1).tryGet()

    (
      await repo.putLeafsAndBlocks(
        treeCid, @[(blk, 0.Natural, proof0), (blk, 1.Natural, proof1)]
      )
    ).tryGet()

    # Verify counters incremented once (unique block)
    check repo.quotaUsedBytes == initialBytes + 100.NBytes
    check repo.totalBlocks == initialBlocks + 1

    # First delete should not remove the block
    (await repo.delBlock(treeCid, 0)).tryGet()
    # Block should not be deleted (refCount was 2, now 1)
    check (await repo.getBlock(blk.cid)).isOk

    # Second delete removes the block
    (await repo.delBlock(treeCid, 1)).tryGet()
    # Block should be deleted (refCount was 1, now 0)
    check (await repo.getBlock(blk.cid)).isErr

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

  test "Should not allow non-orphan blocks to be deleted directly":
    let
      repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes =
          1000'nb)
      dataset = await makeRandomBlocks(datasetSize = 512, blockSize = 256'nb)
      blk = dataset[0]
      (manifest, tree) = makeManifestAndTree(dataset).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    var blocks = BitSeq.init(1)
    blocks.setBit(0)

    (
      await repo.createOrUpdateOverlay(
        treeCid = treeCid, status = OverlayStatus.Completed, blocks = blocks
      )
    ).tryGet
    (await repo.putLeafAndBlock(treeCid, blk, 0, proof)).tryGet
    let err = (await repo.delBlock(blk.cid)).error()
    check err.msg ==
      "Directly deleting a block that is part of a dataset is not allowed."

  test "Should allow non-orphan blocks to be deleted by dataset reference":
    let
      repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes =
          1000'nb)
      dataset = await makeRandomBlocks(datasetSize = 512, blockSize = 256'nb)
      blk = dataset[0]
      (manifest, tree) = makeManifestAndTree(dataset).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    var blocks = BitSeq.init(1)
    blocks.setBit(0)

    (
      await repo.createOrUpdateOverlay(
        treeCid = treeCid, status = OverlayStatus.Completed, blocks = blocks
      )
    ).tryGet
    (await repo.putLeafAndBlock(treeCid, blk, 0, proof)).tryGet

    (await repo.delBlock(treeCid, 0.Natural)).tryGet()
    check not (await blk.cid in repo)

  test "Should not delete a non-orphan block until it is deleted from all parent datasets":
    let
      repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes =
          1024'nb)
      blockPool = await makeRandomBlocks(datasetSize = 768, blockSize = 256'nb)

      dataset1 = @[blockPool[0], blockPool[1]]
      dataset2 = @[blockPool[1], blockPool[2]]
      sharedBlock = blockPool[1]

      (manifest1, tree1) = makeManifestAndTree(dataset1).tryGet()
      treeCid1 = tree1.rootCid.tryGet()
      (manifest2, tree2) = makeManifestAndTree(dataset2).tryGet()
      treeCid2 = tree2.rootCid.tryGet()

    # Create overlay for tree1
    var blocks1 = BitSeq.init(2)
    blocks1.setBit(0)
    blocks1.setBit(1)

    (
      await repo.createOrUpdateOverlay(
        treeCid = treeCid1, status = OverlayStatus.Completed, blocks = blocks1
      )
    ).tryGet()

    # Put dataset1
    let
      proof1_0 = tree1.getProof(0).tryGet()
      proof1_1 = tree1.getProof(1).tryGet()

    (
      await repo.putLeafsAndBlocks(
        treeCid1,
        @[(blockPool[0], 0.Natural, proof1_0), (sharedBlock, 1.Natural, proof1_1)],
      )
    ).tryGet()

    # Shared block should exist with refCount = 1
    check (await repo.blockRefCount(sharedBlock.cid)).tryGet() == 1.Natural

    # Create overlay for tree2
    var blocks2 = BitSeq.init(2)
    blocks2.setBit(0)
    blocks2.setBit(1)

    (
      await repo.createOrUpdateOverlay(
        treeCid = treeCid2, status = OverlayStatus.Completed, blocks = blocks2
      )
    ).tryGet()

    # Put dataset2
    let
      proof2_0 = tree2.getProof(0).tryGet()
      proof2_1 = tree2.getProof(1).tryGet()

    (
      await repo.putLeafsAndBlocks(
        treeCid2,
        @[(sharedBlock, 0.Natural, proof2_0), (blockPool[2], 1.Natural, proof2_1)],
      )
    ).tryGet()

    # Shared block should now have refCount = 2
    check (await repo.blockRefCount(sharedBlock.cid)).tryGet() == 2.Natural

    # Delete from tree1
    (await repo.delBlock(treeCid1, 1.Natural)).tryGet()
    check (await repo.blockRefCount(sharedBlock.cid)).tryGet() == 1.Natural
    check (await sharedBlock.cid in repo)

    # Delete from tree2
    (await repo.delBlock(treeCid2, 0.Natural)).tryGet()
    check not (await sharedBlock.cid in repo)

  test "Should clear leaf metadata when block is deleted from dataset":
    let
      repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes =
          1000'nb)
      dataset = await makeRandomBlocks(datasetSize = 512, blockSize = 256'nb)
      blk = dataset[0]
      (manifest, tree) = makeManifestAndTree(dataset).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    var blocks = BitSeq.init(1)

    (
      await repo.createOrUpdateOverlay(
        treeCid = treeCid, status = OverlayStatus.Completed, blocks = blocks
      )
    ).tryGet()

    (await repo.putLeafsAndBlocks(treeCid, @[(blk, 0.Natural, proof)])).tryGet()

    discard (await repo.getLeafMetadata(treeCid, 0.Natural)).tryGet()

    (await repo.delBlock(treeCid, 0.Natural)).tryGet()

    let err = (await repo.getLeafMetadata(treeCid, 0.Natural)).error()
    check err of BlockNotFoundError

  test "Should not fail when reinserting and deleting a previously deleted block (bug #1108)":
    let
      repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes =
          1000'nb)
      dataset = await makeRandomBlocks(datasetSize = 512, blockSize = 256'nb)
      blk = dataset[0]
      (manifest, tree) = makeManifestAndTree(dataset).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    var blocks = BitSeq.init(1)
    blocks.setBit(0)

    (
      await repo.createOrUpdateOverlay(
        treeCid = treeCid, status = OverlayStatus.Completed, blocks = blocks
      )
    ).tryGet()

    (await repo.putLeafsAndBlocks(treeCid, @[(blk, 0.Natural, proof)])).tryGet()

    (await repo.delBlock(treeCid, 0.Natural)).tryGet()
    (await repo.putLeafsAndBlocks(treeCid, @[(blk, 0.Natural, proof)])).tryGet()
    (await repo.delBlock(treeCid, 0.Natural)).tryGet()

# commonBlockStoreTests(
#   "RepoStore Sql backend",
#   proc(): BlockStore =
#     let tp = Taskpool.new()
#     BlockStore(
#       RepoStore.new(
#         SQLiteKVStore.new(SqliteMemory, tp).tryGet(),
#         SQLiteKVStore.new(SqliteMemory, tp).tryGet(),
#         clock = MockClock.new(),
#       )
#     ),
# )

# const path = currentSourcePath().parentDir / "test"

# proc before() {.async.} =
#   createDir(path)

# proc after() {.async.} =
#   removeDir(path)

# let depth = path.split(DirSep).len

# commonBlockStoreTests(
#   "RepoStore FS backend",
#   proc(): BlockStore =
#     let tp = Taskpool.new()
#     BlockStore(
#       RepoStore.new(
#         FSKVStore.new(path, depth = depth, tp = tp).tryGet(),
#         SQLiteKVStore.new(SqliteMemory, tp).tryGet(),
#         clock = MockClock.new(),
#       )
#     ),
#   before = before,
#   after = after,
# )
