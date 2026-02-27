import std/os
import std/strutils
import std/sequtils
import std/algorithm

import pkg/questionable
import pkg/questionable/results

import pkg/chronos
import pkg/stew/byteutils
import pkg/stew/bitseqs
import pkg/kvstore
import pkg/kvstore/fsds
import pkg/taskpools

import pkg/archivist/chunker
import pkg/archivist/stores
import pkg/archivist/stores/repostore/operations
import pkg/archivist/blocktype as bt
import pkg/archivist/clock
import pkg/archivist/merkletree/archivist

import ../../asynctest
import ../helpers
import ../helpers/mockclock
import ../examples
import ./commonstoretests

var testRepoStoreTmpDir {.threadvar.}: string

commonBlockStoreTests(
  "RepoStore Sql backend",
  proc(): BlockStore =
    let
      tp = Taskpool.new()
      tmpDir = getTempDir() / "repostore_tests"
    testRepoStoreTmpDir = tmpDir
    createDir(tmpDir / "repo")
    createDir(tmpDir / "meta")

    let
      repoDs = FSKVStore.new(tmpDir / "repo", tp, depth = 16).tryGet()
      metaDs = SQLiteKVStore.new(tmpDir / "meta", tp).tryGet()

    let store = RepoStore.new(repoDs, metaDs, clock = MockClock.new())
    BlockStore(store),
  after = proc(): Future[void] {.async, gcsafe.} =
    removeDir(testRepoStoreTmpDir),
)

suite "Test RepoStore start/stop":
  var
    tp: Taskpool
    repoDs: KVStore
    metaDs: KVStore
    tmpDir: string

  setup:
    let path = currentSourcePath()
    tmpDir = path.parentDir / "tests_data"
    createDir(tmpDir / "repo")
    createDir(tmpDir / "meta")

    tp = Taskpool.new()
    repoDs = FSKVStore.new(tmpDir / "repo", tp, depth = 16).tryGet()
    metaDs = SQLiteKVStore.new(tmpDir / "meta", tp).tryGet()

  teardown:
    (await repoDs.close()).tryGet
    (await metaDs.close()).tryGet
    tp.shutdown()
    removeDir(tmpDir)

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
    createDir(basePathAbs / "repo")
    createDir(basePathAbs / "meta")

    tp = Taskpool.new()
    repoDs = FSKVStore.new(basePathAbs / "repo", tp, depth = 16).tryGet()
    metaDs = SQLiteKVStore.new(basePathAbs / "meta", tp).tryGet()
    mockClock = MockClock.new()
    mockClock.set(now)

    repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes = 200'nb)

  teardown:
    (await repoDs.close()).tryGet
    (await metaDs.close()).tryGet
    tp.shutdown()
    removeDir(basePathAbs)

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

    # Build manifest/tree with same block at indices 0 and 1
    let (_, tree) = makeManifestAndTree(@[blk, blk]).tryGet()
    let treeCid = tree.rootCid.tryGet()

    # Create overlay
    var blocks = BitSeq.init(2)

    (await repo.putOverlay(treeCid = treeCid, status = Completed.some, blocks = blocks)).tryGet()

    # Get initial counters
    let
      initialBytes = repo.quotaUsedBytes
      initialBlocks = repo.totalBlocks

      # Put same block at two indices
      proof0 = tree.getProof(0).tryGet()
      proof1 = tree.getProof(1).tryGet()

    (
      await repo.putBlocks(
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
      dataset = (await makeRandomBlocks(datasetSize = 512, blockSize = 256'nb)).tryGet
      blk = dataset[0]
      (_, tree) = makeManifestAndTree(dataset).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    var blocks = BitSeq.init(1)
    blocks.setBit(0)

    (await repo.putOverlay(treeCid = treeCid, status = Completed.some, blocks = blocks)).tryGet
    (await repo.putBlock(treeCid, blk, 0, proof)).tryGet
    let err = (await repo.delBlock(blk.cid)).error()
    check err.msg ==
      "Directly deleting a block that is part of a dataset is not allowed."

  test "Should allow non-orphan blocks to be deleted by dataset reference":
    let
      repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes =
          1000'nb)
      dataset = (await makeRandomBlocks(datasetSize = 512, blockSize = 256'nb)).tryGet
      blk = dataset[0]
      (_, tree) = makeManifestAndTree(dataset).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    var blocks = BitSeq.init(1)
    blocks.setBit(0)

    (await repo.putOverlay(treeCid = treeCid, status = Completed.some, blocks = blocks)).tryGet
    (await repo.putBlock(treeCid, blk, 0, proof)).tryGet

    (await repo.delBlock(treeCid, 0.Natural)).tryGet()
    check not (await blk.cid in repo)

  test "Should not delete a non-orphan block until it is deleted from all parent datasets":
    let
      repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes =
          1024'nb)
      blockPool = (await makeRandomBlocks(datasetSize = 768, blockSize = 256'nb)).tryGet

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
      await repo.putOverlay(
        treeCid = treeCid1, status = Completed.some, blocks = blocks1
      )
    ).tryGet()

    # Put dataset1
    let
      proof1_0 = tree1.getProof(0).tryGet()
      proof1_1 = tree1.getProof(1).tryGet()

    (
      await repo.putBlocks(
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
      await repo.putOverlay(
        treeCid = treeCid2, status = Completed.some, blocks = blocks2
      )
    ).tryGet()

    # Put dataset2
    let
      proof2_0 = tree2.getProof(0).tryGet()
      proof2_1 = tree2.getProof(1).tryGet()

    (
      await repo.putBlocks(
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
      dataset = (await makeRandomBlocks(datasetSize = 512, blockSize = 256'nb)).tryGet
      blk = dataset[0]
      (_, tree) = makeManifestAndTree(dataset).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    var blocks = BitSeq.init(1)

    (await repo.putOverlay(treeCid = treeCid, status = Completed.some, blocks = blocks)).tryGet()

    (await repo.putBlocks(treeCid, @[(blk, 0.Natural, proof)])).tryGet()

    discard (await repo.getLeafMetadata(treeCid, 0.Natural)).tryGet()

    (await repo.delBlock(treeCid, 0.Natural)).tryGet()

    let err = (await repo.getLeafMetadata(treeCid, 0.Natural)).error()
    check err of BlockNotFoundError

  test "Should not fail when reinserting and deleting a previously deleted block (bug #1108)":
    let
      repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes =
          1000'nb)
      dataset = (await makeRandomBlocks(datasetSize = 512, blockSize = 256'nb)).tryGet
      blk = dataset[0]
      (_, tree) = makeManifestAndTree(dataset).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    var blocks = BitSeq.init(1)
    blocks.setBit(0)

    (await repo.putOverlay(treeCid = treeCid, status = Completed.some, blocks = blocks)).tryGet()

    (await repo.putBlocks(treeCid, @[(blk, 0.Natural, proof)])).tryGet()

    (await repo.delBlock(treeCid, 0.Natural)).tryGet()
    (await repo.putBlocks(treeCid, @[(blk, 0.Natural, proof)])).tryGet()
    (await repo.delBlock(treeCid, 0.Natural)).tryGet()

  test "Should handle non-contiguous indices in putBlocks (BitSeq length fix)":
    let
      repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes =
          2000'nb)
      dataset = (await makeRandomBlocks(datasetSize = 2560, blockSize = 256'nb)).tryGet
      blk = dataset[0]
      (_, tree) = makeManifestAndTree(dataset).tryGet()
      treeCid = tree.rootCid.tryGet()

    # Create overlay with 10 blocks, but only insert at index 5
    var blocks = BitSeq.init(10)

    (await repo.putOverlay(treeCid = treeCid, status = Completed.some, blocks = blocks)).tryGet()

    # Put only index 5 (non-contiguous)
    let proof = tree.getProof(5).tryGet()
    (await repo.putBlocks(treeCid, @[(blk, 5.Natural, proof)])).tryGet()

    # Verify block was stored
    check (await repo.getBlock(blk.cid)).isOk
    check repo.quotaUsedBytes == 256.NBytes

    # Verify overlay has correct bit set
    let overlayMeta = (await repo.getOverlay(treeCid)).tryGet()
    check overlayMeta.blocks.len == 10
    check overlayMeta.blocks[5] == true

  test "Should correctly handle multi-index delete with same block CID (refCount aggregation)":
    let
      repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes =
          2000'nb)
      blk = createTestBlock(256)

    # Create tree with same block at indices 1, 3, and 5
    let (_, tree) = makeManifestAndTree(@[blk, blk, blk, blk, blk, blk]).tryGet()
    let treeCid = tree.rootCid.tryGet()

    var blocks = BitSeq.init(6)
    blocks.setBit(1)
    blocks.setBit(3)
    blocks.setBit(5)

    (await repo.putOverlay(treeCid = treeCid, status = Completed.some, blocks = blocks)).tryGet()

    # Put same block at indices 1, 3, and 5
    let
      proof1 = tree.getProof(1).tryGet()
      proof3 = tree.getProof(3).tryGet()
      proof5 = tree.getProof(5).tryGet()

    (
      await repo.putBlocks(
        treeCid,
        @[(blk, 1.Natural, proof1), (blk, 3.Natural, proof3), (blk, 5.Natural, proof5)],
      )
    ).tryGet()

    # Verify refCount = 3
    check (await repo.blockRefCount(blk.cid)).tryGet() == 3.Natural
    check repo.quotaUsedBytes == 256.NBytes

    # Delete all three indices in ONE call (tests aggregation in delLeafBlockMetadata)
    (await repo.delLeafBlockMetadata(treeCid, @[1.Natural, 3.Natural, 5.Natural])).tryGet()

    # Verify block is deleted (refCount went from 3 to 0 in one atomic operation)
    check not (await blk.cid in repo)
    check repo.quotaUsedBytes == 0.NBytes

  test "Should restore deleted leaf on re-put (crash recovery resurrection)":
    let
      repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes =
          1000'nb)
      dataset = (await makeRandomBlocks(datasetSize = 512, blockSize = 256'nb)).tryGet
      blk = dataset[0]
      (_, tree) = makeManifestAndTree(dataset).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    var blocks = BitSeq.init(1)
    blocks.setBit(0)

    (await repo.putOverlay(treeCid = treeCid, status = Completed.some, blocks = blocks)).tryGet()

    # Put block first
    (await repo.putBlocks(treeCid, @[(blk, 0.Natural, proof)])).tryGet()
    check (await repo.getBlock(blk.cid)).isOk

    # Delete block (marks leaf as deleted, but don't physically remove yet)
    (await repo.delBlock(treeCid, 0.Natural)).tryGet()
    check not (await blk.cid in repo)

    # Re-put the same block (should restore deleted leaf via resurrection logic)
    (await repo.putBlocks(treeCid, @[(blk, 0.Natural, proof)])).tryGet()

    # Verify block is back
    check (await repo.getBlock(blk.cid)).isOk
    check (await repo.blockRefCount(blk.cid)).tryGet() == 1.Natural

    # Verify leaf metadata is correct (not marked as deleted)
    let restoredLeaf = (await repo.getLeafMetadata(treeCid, 0.Natural)).tryGet()
    check restoredLeaf.blkCid == blk.cid
    check restoredLeaf.deleted == false

suite "Test RepoStore Batch Operations":
  var
    repoDs: FSKVStore
    metaDs: SQLiteKVStore
    repoStore: RepoStore
    tp: Taskpool
    tmpDir: string

  setup:
    let path = currentSourcePath()
    tmpDir = path.parentDir / "batch_tests_data"
    createDir(tmpDir / "repo")
    createDir(tmpDir / "meta")
    tp = Taskpool.new(num_threads = 4)
    repoDs = FSKVStore.new(tmpDir / "repo", tp, depth = 16).tryGet()
    metaDs = SQLiteKVStore.new(tmpDir / "meta", tp).tryGet()
    repoStore = RepoStore.new(repoDs, metaDs, quotaMaxBytes = 200000'nb)
    await repoStore.start()

  teardown:
    await repoStore.stop()
    tp.shutdown()
    removeDir(tmpDir)

  proc createTestBlock(size: int): bt.Block =
    bt.Block.new('a'.repeat(size).toBytes).tryGet()

  # Tests for getBlocks(cids: seq[Cid]) - raw CID batch
  test "should get multiple blocks by CID":
    let
      blk1 = createTestBlock(100)
      blk2 = createTestBlock(150)
      blk3 = createTestBlock(200)

    # Store blocks using deprecated putBlock method
    (await repoStore.putBlock(blk1)).tryGet()
    (await repoStore.putBlock(blk2)).tryGet()
    (await repoStore.putBlock(blk3)).tryGet()

    # Retrieve all three blocks
    let blocks = (await repoStore.getBlocks(@[blk1.cid, blk2.cid, blk3.cid])).tryGet()
    let returnedCids = blocks.mapIt(it.cid)

    check blocks.len == 3
    check blk1.cid in returnedCids
    check blk2.cid in returnedCids
    check blk3.cid in returnedCids

  test "should return empty seq for empty input":
    let blocks = (await repoStore.getBlocks(newSeq[Cid]())).tryGet()
    check blocks.len == 0

  test "should skip missing CIDs":
    let
      blk1 = createTestBlock(100)
      blk2 = createTestBlock(150)

    # Store only 2 blocks
    (await repoStore.putBlock(blk1)).tryGet()
    (await repoStore.putBlock(blk2)).tryGet()

    # Request 3 CIDs (one missing)
    let missingCid = Cid.example
    let blocks = (await repoStore.getBlocks(@[blk1.cid, missingCid, blk2.cid])).tryGet()

    # Should return only the 2 existing blocks
    check blocks.len == 2

  test "should handle empty CIDs":
    let
      blk1 = createTestBlock(100)
      emptyBlk = Cid.example.emptyBlock.tryGet()

    # Store one real block
    (await repoStore.putBlock(blk1)).tryGet()

    # Request real + empty CID
    let blocks = (await repoStore.getBlocks(@[blk1.cid, emptyBlk.cid])).tryGet()

    # Should return the real block and synthesized empty block
    check blocks.len == 2

  # Tests for getBlocks(treeCid, indices) - tree-based batch
  test "should get multiple blocks by tree and indices":
    let
      dataset = (await makeRandomBlocks(datasetSize = 768, blockSize = 256'nb)).tryGet
      (_, tree) = makeManifestAndTree(dataset).tryGet()
      treeCid = tree.rootCid.tryGet()

    var blocks = BitSeq.init(3)
    blocks.setBit(0)
    blocks.setBit(1)
    blocks.setBit(2)

    (
      await repoStore.putOverlay(
        treeCid = treeCid, status = Completed.some, blocks = blocks
      )
    ).tryGet()

    let
      proof0 = tree.getProof(0).tryGet()
      proof1 = tree.getProof(1).tryGet()
      proof2 = tree.getProof(2).tryGet()

    (
      await repoStore.putBlocks(
        treeCid,
        @[
          (dataset[0], 0.Natural, proof0),
          (dataset[1], 1.Natural, proof1),
          (dataset[2], 2.Natural, proof2),
        ],
      )
    ).tryGet()

    # Retrieve all three blocks
    let unsorted =
      (await repoStore.getBlocks(treeCid, @[0.Natural, 1.Natural, 2.Natural])).tryGet()
    let results = unsorted.sortedByIt(it[0])

    check results.len == 3
    check results[0][0] == 0.Natural
    check results[0][1].cid == dataset[0].cid
    check results[1][0] == 1.Natural
    check results[1][1].cid == dataset[1].cid
    check results[2][0] == 2.Natural
    check results[2][1].cid == dataset[2].cid

  test "should return empty seq for empty indices":
    let
      dataset = (await makeRandomBlocks(datasetSize = 256, blockSize = 256'nb)).tryGet
      (_, tree) = makeManifestAndTree(dataset).tryGet()
      treeCid = tree.rootCid.tryGet()

    var blocks = BitSeq.init(1)
    blocks.setBit(0)

    (
      await repoStore.putOverlay(
        treeCid = treeCid, status = Completed.some, blocks = blocks
      )
    ).tryGet()

    let proof = tree.getProof(0).tryGet()
    (await repoStore.putBlocks(treeCid, @[(dataset[0], 0.Natural, proof)])).tryGet()

    # Request empty indices
    let results = (await repoStore.getBlocks(treeCid, newSeq[Natural]())).tryGet()

    check results.len == 0

  test "should skip missing indices":
    let
      dataset = (await makeRandomBlocks(datasetSize = 768, blockSize = 256'nb)).tryGet
      (_, tree) = makeManifestAndTree(dataset).tryGet()
      treeCid = tree.rootCid.tryGet()

    var blocks = BitSeq.init(3)
    blocks.setBit(0)
    blocks.setBit(1)
    blocks.setBit(2)

    (
      await repoStore.putOverlay(
        treeCid = treeCid, status = Completed.some, blocks = blocks
      )
    ).tryGet()

    let
      proof0 = tree.getProof(0).tryGet()
      proof1 = tree.getProof(1).tryGet()
      proof2 = tree.getProof(2).tryGet()

    (
      await repoStore.putBlocks(
        treeCid,
        @[
          (dataset[0], 0.Natural, proof0),
          (dataset[1], 1.Natural, proof1),
          (dataset[2], 2.Natural, proof2),
        ],
      )
    ).tryGet()

    # Request indices 0,1,2,5 (5 is missing)
    let results = (
      await repoStore.getBlocks(treeCid, @[0.Natural, 1.Natural, 2.Natural, 5.Natural])
    ).tryGet()

    # Should return only 0,1,2
    check results.len == 3

  test "should handle indices not in bitmap":
    let
      dataset = (await makeRandomBlocks(datasetSize = 512, blockSize = 256'nb)).tryGet
      (_, tree) = makeManifestAndTree(dataset).tryGet()
      treeCid = tree.rootCid.tryGet()

    # Create overlay with only 2 blocks but request indices beyond
    var blocks = BitSeq.init(2)
    blocks.setBit(0)
    blocks.setBit(1)

    (
      await repoStore.putOverlay(
        treeCid = treeCid, status = Completed.some, blocks = blocks
      )
    ).tryGet()

    let
      proof0 = tree.getProof(0).tryGet()
      proof1 = tree.getProof(1).tryGet()

    (
      await repoStore.putBlocks(
        treeCid, @[(dataset[0], 0.Natural, proof0), (dataset[1], 1.Natural, proof1)]
      )
    ).tryGet()

    # Request indices beyond bitmap length
    let results =
      (await repoStore.getBlocks(treeCid, @[0.Natural, 5.Natural, 10.Natural])).tryGet()

    # Should return only index 0
    check results.len == 1
    check results[0][0] == 0.Natural

  # Tests for getBlocksAndProofs(treeCid, indices)
  test "should get blocks and proofs":
    let
      dataset = (await makeRandomBlocks(datasetSize = 768, blockSize = 256'nb)).tryGet
      (_, tree) = makeManifestAndTree(dataset).tryGet()
      treeCid = tree.rootCid.tryGet()

    var blocks = BitSeq.init(3)
    blocks.setBit(0)
    blocks.setBit(1)
    blocks.setBit(2)

    (
      await repoStore.putOverlay(
        treeCid = treeCid, status = Completed.some, blocks = blocks
      )
    ).tryGet()

    let
      proof0 = tree.getProof(0).tryGet()
      proof1 = tree.getProof(1).tryGet()
      proof2 = tree.getProof(2).tryGet()

    (
      await repoStore.putBlocks(
        treeCid,
        @[
          (dataset[0], 0.Natural, proof0),
          (dataset[1], 1.Natural, proof1),
          (dataset[2], 2.Natural, proof2),
        ],
      )
    ).tryGet()

    # Retrieve blocks with proofs
    let unsorted = (
      await repoStore.getBlocksAndProofs(treeCid, @[0.Natural, 1.Natural, 2.Natural])
    ).tryGet()
    let results = unsorted.sortedByIt(it[0])

    check results.len == 3
    check results[0][0] == 0.Natural
    check results[0][1].cid == dataset[0].cid
    check $results[0][2] == $proof0
    check results[1][0] == 1.Natural
    check results[1][1].cid == dataset[1].cid
    check $results[1][2] == $proof1
    check results[2][0] == 2.Natural
    check results[2][1].cid == dataset[2].cid
    check $results[2][2] == $proof2

  test "should return empty for empty input":
    let
      dataset = (await makeRandomBlocks(datasetSize = 256, blockSize = 256'nb)).tryGet
      (_, tree) = makeManifestAndTree(dataset).tryGet()
      treeCid = tree.rootCid.tryGet()

    var blocks = BitSeq.init(1)
    blocks.setBit(0)

    (
      await repoStore.putOverlay(
        treeCid = treeCid, status = Completed.some, blocks = blocks
      )
    ).tryGet()

    let proof = tree.getProof(0).tryGet()
    (await repoStore.putBlocks(treeCid, @[(dataset[0], 0.Natural, proof)])).tryGet()

    # Request empty indices
    let results =
      (await repoStore.getBlocksAndProofs(treeCid, newSeq[Natural]())).tryGet()

    check results.len == 0

  # Tests for hasBlocks(treeCid, indices)
  test "should report existing blocks":
    let
      dataset = (await makeRandomBlocks(datasetSize = 768, blockSize = 256'nb)).tryGet
      (_, tree) = makeManifestAndTree(dataset).tryGet()
      treeCid = tree.rootCid.tryGet()

    var blocks = BitSeq.init(3)
    blocks.setBit(0)
    blocks.setBit(1)
    blocks.setBit(2)

    (
      await repoStore.putOverlay(
        treeCid = treeCid, status = Completed.some, blocks = blocks
      )
    ).tryGet()

    let
      proof0 = tree.getProof(0).tryGet()
      proof1 = tree.getProof(1).tryGet()
      proof2 = tree.getProof(2).tryGet()

    (
      await repoStore.putBlocks(
        treeCid,
        @[
          (dataset[0], 0.Natural, proof0),
          (dataset[1], 1.Natural, proof1),
          (dataset[2], 2.Natural, proof2),
        ],
      )
    ).tryGet()

    # Check which blocks exist
    let unsorted =
      (await repoStore.hasBlocks(treeCid, @[0.Natural, 1.Natural, 2.Natural])).tryGet()
    let results = unsorted.sortedByIt(it[0])

    check results.len == 3
    check results[0][0] == 0.Natural
    check results[0][1] == true
    check results[1][0] == 1.Natural
    check results[1][1] == true
    check results[2][0] == 2.Natural
    check results[2][1] == true

  test "should not report missing blocks":
    let
      dataset = (await makeRandomBlocks(datasetSize = 768, blockSize = 256'nb)).tryGet
      (_, tree) = makeManifestAndTree(dataset).tryGet()
      treeCid = tree.rootCid.tryGet()

    var blocks = BitSeq.init(3)
    blocks.setBit(0)
    blocks.setBit(2)

    (
      await repoStore.putOverlay(
        treeCid = treeCid, status = Completed.some, blocks = blocks
      )
    ).tryGet()

    let
      proof0 = tree.getProof(0).tryGet()
      proof2 = tree.getProof(2).tryGet()

    (
      await repoStore.putBlocks(
        treeCid, @[(dataset[0], 0.Natural, proof0), (dataset[2], 2.Natural, proof2)]
      )
    ).tryGet()

    # Check indices 0,1,2 - only 0 and 2 exist
    let unsorted2 =
      (await repoStore.hasBlocks(treeCid, @[0.Natural, 1.Natural, 2.Natural])).tryGet()
    let results = unsorted2.sortedByIt(it[0])

    check results.len == 3
    check results[0][0] == 0.Natural
    check results[0][1] == true
    check results[1][0] == 1.Natural
    check results[1][1] == false
    check results[2][0] == 2.Natural
    check results[2][1] == true

  # Tests for delBlocks(treeCid, indices)
  test "should delete multiple blocks":
    let
      dataset = (await makeRandomBlocks(datasetSize = 768, blockSize = 256'nb)).tryGet
      (_, tree) = makeManifestAndTree(dataset).tryGet()
      treeCid = tree.rootCid.tryGet()

    var blocks = BitSeq.init(3)
    blocks.setBit(0)
    blocks.setBit(1)
    blocks.setBit(2)

    (
      await repoStore.putOverlay(
        treeCid = treeCid, status = Completed.some, blocks = blocks
      )
    ).tryGet()

    let
      proof0 = tree.getProof(0).tryGet()
      proof1 = tree.getProof(1).tryGet()
      proof2 = tree.getProof(2).tryGet()

    (
      await repoStore.putBlocks(
        treeCid,
        @[
          (dataset[0], 0.Natural, proof0),
          (dataset[1], 1.Natural, proof1),
          (dataset[2], 2.Natural, proof2),
        ],
      )
    ).tryGet()

    # Verify all blocks exist
    check (await repoStore.hasBlock(treeCid, 0.Natural)).tryGet() == true
    check (await repoStore.hasBlock(treeCid, 1.Natural)).tryGet() == true
    check (await repoStore.hasBlock(treeCid, 2.Natural)).tryGet() == true

    # Delete indices 0 and 2
    (await repoStore.delBlocks(treeCid, @[0.Natural, 2.Natural])).tryGet()

    # Verify only index 1 remains
    check (await repoStore.hasBlock(treeCid, 0.Natural)).tryGet() == false
    check (await repoStore.hasBlock(treeCid, 1.Natural)).tryGet() == true
    check (await repoStore.hasBlock(treeCid, 2.Natural)).tryGet() == false
