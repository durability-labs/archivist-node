import std/os
import std/strutils
import std/sequtils

import pkg/questionable
import pkg/questionable/results

import pkg/chronos
import pkg/stew/byteutils
import pkg/kvstore
from pkg/kvstore/sql/sqlitedsdb import SqliteMemory

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
    blockStore: KVStore
    metaStore: KVStore

  setup:
    blockStore = SQLiteKVStore.new(SqliteMemory).tryGet()
    metaStore = SQLiteKVStore.new(SqliteMemory).tryGet()

  test "Should set started flag once started":
    let repo = RepoStore.new(metaStore, blockStore, quotaMaxBytes = 200'nb)
    await repo.start()
    check repo.started

  test "Should set started flag to false once stopped":
    let repo = RepoStore.new(metaStore, blockStore, quotaMaxBytes = 200'nb)
    await repo.start()
    await repo.stop()
    check not repo.started

  test "Should allow start to be called multiple times":
    let repo = RepoStore.new(metaStore, blockStore, quotaMaxBytes = 200'nb)
    await repo.start()
    await repo.start()
    check repo.started

  test "Should allow stop to be called multiple times":
    let repo = RepoStore.new(metaStore, blockStore, quotaMaxBytes = 200'nb)
    await repo.stop()
    await repo.stop()
    check not repo.started

asyncchecksuite "RepoStore":
  var
    blockStore: KVStore
    metaStore: KVStore
    mockClock: MockClock

    repo: RepoStore

  let now: SecondsSince1970 = 123

  setup:
    blockStore = SQLiteKVStore.new(SqliteMemory).tryGet()
    metaStore = SQLiteKVStore.new(SqliteMemory).tryGet()
    mockClock = MockClock.new()
    mockClock.set(now)

    repo =
      RepoStore.new(metaStore, blockStore, clock = mockClock, quotaMaxBytes = 200'nb)

  teardown:
    (await blockStore.close()).tryGet
    (await metaStore.close()).tryGet

  proc createTestBlock(size: int): bt.Block =
    bt.Block.new('a'.repeat(size).toBytes).tryGet()

  test "Should update current used bytes on block put":
    let blk = createTestBlock(200)

    check repo.quotaUsedBytes == 0'nb
    (await repo.putBlock(blk)).tryGet

    check:
      repo.quotaUsedBytes == 200'nb

  test "Should update current used bytes on block delete":
    let blk = createTestBlock(100)

    check repo.quotaUsedBytes == 0'nb
    (await repo.putBlock(blk)).tryGet
    check repo.quotaUsedBytes == 100'nb

    (await repo.delBlock(blk.cid)).tryGet

    check:
      repo.quotaUsedBytes == 0'nb

  test "Should not update current used bytes if block exist":
    let blk = createTestBlock(100)

    check repo.quotaUsedBytes == 0'nb
    (await repo.putBlock(blk)).tryGet
    check repo.quotaUsedBytes == 100'nb

    # put again
    (await repo.putBlock(blk)).tryGet
    check repo.quotaUsedBytes == 100'nb

  test "Should fail storing passed the quota":
    let blk = createTestBlock(300)

    check repo.totalUsed == 0'nb
    expect QuotaNotEnoughError:
      (await repo.putBlock(blk)).tryGet

  test "Should reserve bytes":
    let blk = createTestBlock(100)

    check repo.totalUsed == 0'nb
    (await repo.putBlock(blk)).tryGet
    check repo.totalUsed == 100'nb

    (await repo.reserve(100'nb)).tryGet

    check:
      repo.totalUsed == 200'nb
      repo.quotaUsedBytes == 100'nb
      repo.quotaReservedBytes == 100'nb

  test "Should not reserve bytes over max quota":
    let blk = createTestBlock(100)

    check repo.totalUsed == 0'nb
    (await repo.putBlock(blk)).tryGet
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

    expect RangeDefect:
      (await repo.release(101'nb)).tryGet

    check:
      repo.totalUsed == 100'nb
      repo.quotaUsedBytes == 0'nb
      repo.quotaReservedBytes == 100'nb

  test "should put empty blocks":
    let blk = Cid.example.emptyBlock.tryGet()
    check (await repo.putBlock(blk)).isOk

  test "should get empty blocks":
    let blk = Cid.example.emptyBlock.tryGet()

    let got = await repo.getBlock(blk.cid)
    check got.isOk
    check got.get.cid == blk.cid

  test "should delete empty blocks":
    let blk = Cid.example.emptyBlock.tryGet()
    check (await repo.delBlock(blk.cid)).isOk

  test "should have empty block":
    let blk = Cid.example.emptyBlock.tryGet()

    let has = await repo.hasBlock(blk.cid)
    check has.isOk
    check has.get

  test "should set the reference count for orphan blocks to 0":
    let blk = Block.example(size = 200)
    (await repo.putBlock(blk)).tryGet()
    check (await repo.blockRefCount(blk.cid)).tryGet() == 0.Natural

  test "should not allow non-orphan blocks to be deleted directly":
    let
      repo =
        RepoStore.new(metaStore, blockStore, clock = mockClock, quotaMaxBytes =
            1000'nb)
      dataset = await makeRandomBlocks(datasetSize = 512, blockSize = 256'nb)
      blk = dataset[0]
      (manifest, tree) = makeManifestAndTree(dataset).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    (await repo.putBlock(blk)).tryGet()
    (await repo.putCidAndProof(treeCid, 0, blk.cid, proof)).tryGet()

    let err = (await repo.delBlock(blk.cid)).error()
    check err.msg ==
      "Directly deleting a block that is part of a dataset is not allowed."

  test "should allow non-orphan blocks to be deleted by dataset reference":
    let
      repo =
        RepoStore.new(metaStore, blockStore, clock = mockClock, quotaMaxBytes =
            1000'nb)
      dataset = await makeRandomBlocks(datasetSize = 512, blockSize = 256'nb)
      blk = dataset[0]
      (manifest, tree) = makeManifestAndTree(dataset).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(0).tryGet()

    (await repo.putBlock(blk)).tryGet()
    (await repo.putCidAndProof(treeCid, 0, blk.cid, proof)).tryGet()

    (await repo.delBlock(treeCid, 0.Natural)).tryGet()
    check not (await blk.cid in repo)

  test "should not delete a non-orphan block until it is deleted from all parent datasets":
    let
      repo =
        RepoStore.new(metaStore, blockStore, clock = mockClock, quotaMaxBytes =
            1000'nb)
      blockPool = await makeRandomBlocks(datasetSize = 768, blockSize = 256'nb)

    let
      dataset1 = @[blockPool[0], blockPool[1]]
      dataset2 = @[blockPool[1], blockPool[2]]

    let sharedBlock = blockPool[1]

    let
      (manifest1, tree1) = makeManifestAndTree(dataset1).tryGet()
      treeCid1 = tree1.rootCid.tryGet()
      (manifest2, tree2) = makeManifestAndTree(dataset2).tryGet()
      treeCid2 = tree2.rootCid.tryGet()

    (await repo.putBlock(sharedBlock)).tryGet()
    check (await repo.blockRefCount(sharedBlock.cid)).tryGet() == 0.Natural

    let
      proof1 = tree1.getProof(1).tryGet()
      proof2 = tree2.getProof(0).tryGet()

    (await repo.putCidAndProof(treeCid1, 1, sharedBlock.cid, proof1)).tryGet()
    check (await repo.blockRefCount(sharedBlock.cid)).tryGet() == 1.Natural

    (await repo.putCidAndProof(treeCid2, 0, sharedBlock.cid, proof2)).tryGet()
    check (await repo.blockRefCount(sharedBlock.cid)).tryGet() == 2.Natural

    (await repo.delBlock(treeCid1, 1.Natural)).tryGet()
    check (await repo.blockRefCount(sharedBlock.cid)).tryGet() == 1.Natural
    check (await sharedBlock.cid in repo)

    (await repo.delBlock(treeCid2, 0.Natural)).tryGet()
    check not (await sharedBlock.cid in repo)

  test "should clear leaf metadata when block is deleted from dataset":
    let
      repo =
        RepoStore.new(metaStore, blockStore, clock = mockClock, quotaMaxBytes =
            1000'nb)
      dataset = await makeRandomBlocks(datasetSize = 512, blockSize = 256'nb)
      blk = dataset[0]
      (manifest, tree) = makeManifestAndTree(dataset).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(1).tryGet()

    (await repo.putBlock(blk)).tryGet()
    (await repo.putCidAndProof(treeCid, 0.Natural, blk.cid, proof)).tryGet()

    discard (await repo.getLeafCid(treeCid, 0.Natural)).tryGet()

    (await repo.delBlock(treeCid, 0.Natural)).tryGet()

    let err = (await repo.getLeafCid(treeCid, 0.Natural)).error()
    check err of BlockNotFoundError

  test "should not fail when reinserting and deleting a previously deleted block (bug #1108)":
    let
      repo =
        RepoStore.new(metaStore, blockStore, clock = mockClock, quotaMaxBytes =
            1000'nb)
      dataset = await makeRandomBlocks(datasetSize = 512, blockSize = 256'nb)
      blk = dataset[0]
      (manifest, tree) = makeManifestAndTree(dataset).tryGet()
      treeCid = tree.rootCid.tryGet()
      proof = tree.getProof(1).tryGet()

    (await repo.putBlock(blk)).tryGet()
    (await repo.putCidAndProof(treeCid, 0, blk.cid, proof)).tryGet()

    (await repo.delBlock(treeCid, 0.Natural)).tryGet()
    (await repo.putBlock(blk)).tryGet()
    (await repo.delBlock(treeCid, 0.Natural)).tryGet()

commonBlockStoreTests(
  "RepoStore Sql backend",
  proc(): BlockStore =
    BlockStore(
      RepoStore.new(
        SQLiteKVStore.new(SqliteMemory).tryGet(),
        SQLiteKVStore.new(SqliteMemory).tryGet(),
        clock = MockClock.new(),
      )
    ),
)

const path = currentSourcePath().parentDir / "test"

proc before() {.async.} =
  createDir(path)

proc after() {.async.} =
  removeDir(path)

let depth = path.split(DirSep).len

commonBlockStoreTests(
  "RepoStore FS backend",
  proc(): BlockStore =
    BlockStore(
      RepoStore.new(
        SQLiteKVStore.new(SqliteMemory).tryGet(),
        FSKVStore.new(path, depth).tryGet(),
        clock = MockClock.new(),
      )
    ),
  before = before,
  after = after,
)
