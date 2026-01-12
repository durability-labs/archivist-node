import std/sequtils

import pkg/chronos
import pkg/kvstore/sql
from pkg/kvstore/sql/sqlitedsdb import SqliteMemory
import pkg/questionable
import pkg/questionable/results

import pkg/archivist/blocktype as bt
import pkg/archivist/clock
import pkg/archivist/datasetmanager/manager
import pkg/archivist/datasetmanager/store
import pkg/archivist/datasetmanager/types
import pkg/archivist/manifest
import pkg/archivist/merkletree
import pkg/archivist/units

import ../../asynctest
import ../helpers
import ../helpers/mockclock
import ../helpers/mockblockstore
import ../examples

suite "DatasetManager State Management":
  var
    metaStore: SQLiteKVStore
    datasetStore: DatasetStore
    mockClock: MockClock
    mockStore: MockBlockStore
    dm: DatasetManager

  let now: SecondsSince1970 = 1000

  setup:
    metaStore = SQLiteKVStore.new(SqliteMemory).tryGet()
    datasetStore = DatasetStore.new(metaStore)
    mockClock = MockClock.new()
    mockClock.set(now)
    mockStore = MockBlockStore.new()
    # Note: engine is nil for these tests since we're only testing state management
    dm = DatasetManager.new(mockStore, datasetStore, nil, mockClock)

  teardown:
    (await datasetStore.close()).tryGet()

  test "Should store and retrieve overlay metadata":
    let
      treeCid = Cid.example
      manifestCid = Cid.example
      meta = OverlayMetadata(
        status: Downloading,
        manifestCid: manifestCid,
        totalBlocks: 100,
        totalSize: 1024'u64 * 1024,
        expiry: now + 3600,
        kind: DatasetOverlay,
        parentTreeCid: Cid.none,
      )

    (await datasetStore.setOverlayMetadata(treeCid, meta)).tryGet()

    let retrieved = (await datasetStore.getOverlayMetadata(treeCid)).tryGet()

    check:
      retrieved.status == Downloading
      retrieved.manifestCid == manifestCid
      retrieved.totalBlocks == 100'u32
      retrieved.totalSize == 1024'u64 * 1024
      retrieved.expiry == now + 3600
      retrieved.kind == DatasetOverlay
      retrieved.parentTreeCid.isNone

  test "Should update overlay metadata status":
    let
      treeCid = Cid.example
      manifestCid = Cid.example
      meta1 = OverlayMetadata(
        status: Downloading,
        manifestCid: manifestCid,
        totalBlocks: 50,
        totalSize: 512,
        expiry: now + 1800,
        kind: DatasetOverlay,
      )

    (await datasetStore.setOverlayMetadata(treeCid, meta1)).tryGet()

    var meta2 = meta1
    meta2.status = Completed

    (await datasetStore.setOverlayMetadata(treeCid, meta2)).tryGet()

    let retrieved = (await datasetStore.getOverlayMetadata(treeCid)).tryGet()
    check retrieved.status == Completed

  test "Should delete overlay metadata":
    let
      treeCid = Cid.example
      manifestCid = Cid.example
      meta = OverlayMetadata(
        status: Completed,
        manifestCid: manifestCid,
        totalBlocks: 10,
        totalSize: 100,
        expiry: now + 7200,
        kind: DatasetOverlay,
      )

    (await datasetStore.setOverlayMetadata(treeCid, meta)).tryGet()
    (await datasetStore.deleteOverlayMetadata(treeCid)).tryGet()

    let result = await datasetStore.getOverlayMetadata(treeCid)
    check result.isErr

  test "Should list all datasets":
    let
      treeCid1 = Cid.example
      treeCid2 = Cid.example
      treeCid3 = Cid.example

    for treeCid in [treeCid1, treeCid2, treeCid3]:
      let meta = OverlayMetadata(
        status: Completed,
        manifestCid: Cid.example,
        totalBlocks: 10,
        totalSize: 100,
        expiry: now + 3600,
        kind: DatasetOverlay,
      )
      (await datasetStore.setOverlayMetadata(treeCid, meta)).tryGet()

    let datasets = (await datasetStore.listDatasets()).tryGet()
    check datasets.len == 3

  test "Should list datasets filtered by state":
    let
      treeCidCompleted1 = Cid.example
      treeCidCompleted2 = Cid.example
      treeCidDownloading = Cid.example

    (
      await datasetStore.setOverlayMetadata(
        treeCidCompleted1,
        OverlayMetadata(
          status: Completed,
          manifestCid: Cid.example,
          totalBlocks: 10,
          totalSize: 100,
          expiry: now + 3600,
          kind: DatasetOverlay,
        ),
      )
    ).tryGet()

    (
      await datasetStore.setOverlayMetadata(
        treeCidCompleted2,
        OverlayMetadata(
          status: Completed,
          manifestCid: Cid.example,
          totalBlocks: 20,
          totalSize: 200,
          expiry: now + 3600,
          kind: DatasetOverlay,
        ),
      )
    ).tryGet()

    (
      await datasetStore.setOverlayMetadata(
        treeCidDownloading,
        OverlayMetadata(
          status: Downloading,
          manifestCid: Cid.example,
          totalBlocks: 30,
          totalSize: 300,
          expiry: now + 3600,
          kind: DatasetOverlay,
        ),
      )
    ).tryGet()

    let
      completedDatasets = (await datasetStore.listDatasetsInState(Completed)).tryGet()
      downloadingDatasets = (await datasetStore.listDatasetsInState(Downloading)).tryGet()
      deletingDatasets = (await datasetStore.listDatasetsInState(Deleting)).tryGet()

    check:
      completedDatasets.len == 2
      downloadingDatasets.len == 1
      deletingDatasets.len == 0

  test "Should store slot overlay with parent reference":
    let
      parentTreeCid = Cid.example
      slotTreeCid = Cid.example
      slotManifestCid = Cid.example
      meta = OverlayMetadata(
        status: Completed,
        manifestCid: slotManifestCid,
        totalBlocks: 5,
        totalSize: 50,
        expiry: now + 3600,
        kind: SlotOverlay,
        parentTreeCid: parentTreeCid.some,
      )

    (await datasetStore.setOverlayMetadata(slotTreeCid, meta)).tryGet()

    let retrieved = (await datasetStore.getOverlayMetadata(slotTreeCid)).tryGet()

    check:
      retrieved.kind == SlotOverlay
      retrieved.parentTreeCid.isSome
      retrieved.parentTreeCid.get == parentTreeCid

suite "DatasetManager Lifecycle Operations":
  var
    metaStore: SQLiteKVStore
    datasetStore: DatasetStore
    mockClock: MockClock
    mockStore: MockBlockStore
    dm: DatasetManager

  let now: SecondsSince1970 = 1000

  setup:
    metaStore = SQLiteKVStore.new(SqliteMemory).tryGet()
    datasetStore = DatasetStore.new(metaStore)
    mockClock = MockClock.new()
    mockClock.set(now)
    mockStore = MockBlockStore.new()
    # Note: engine is nil - tests that don't require network retrieval
    dm = DatasetManager.new(mockStore, datasetStore, nil, mockClock)

  teardown:
    (await datasetStore.close()).tryGet()

  proc createManifestBlock(treeCid: Cid, blocksCount: int, blockSize: int): bt.Block =
    ## Helper to create a manifest block for testing
    let manifest = Manifest.new(
      treeCid = treeCid,
      blockSize = blockSize.NBytes,
      datasetSize = (blocksCount * blockSize).NBytes,
    )
    let encoded = manifest.encode().tryGet()
    bt.Block.new(encoded, codec = ManifestCodec).tryGet()

  test "downloadDataset should skip if already completed":
    let
      treeCid = Cid.example
      manifestBlk = createManifestBlock(treeCid, blocksCount = 2, blockSize = 256)
      manifestCid = manifestBlk.cid

    let meta = OverlayMetadata(
      status: Completed,
      manifestCid: manifestCid,
      totalBlocks: 2,
      totalSize: 512,
      expiry: now + 3600,
      kind: DatasetOverlay,
    )
    (await datasetStore.setOverlayMetadata(treeCid, meta)).tryGet()
    (await mockStore.putBlock(manifestBlk)).tryGet()

    let result = await dm.downloadDataset(manifestCid)
    check result.isOk

    let retrieved = (await datasetStore.getOverlayMetadata(treeCid)).tryGet()
    check retrieved.status == Completed

  test "getProgress should return correct counts":
    let
      treeCid = Cid.example
      manifestBlk = createManifestBlock(treeCid, blocksCount = 4, blockSize = 256)
      manifestCid = manifestBlk.cid

    var blocks: seq[bt.Block] = @[]
    for i in 0 ..< 4:
      blocks.add(bt.Block.example(size = 256))

    (await mockStore.putBlock(manifestBlk)).tryGet()
    for i, blk in blocks:
      (await mockStore.putBlock(blk)).tryGet()
      (await mockStore.putCidAndProof(treeCid, i, blk.cid, ArchivistProof())).tryGet()

    let meta = OverlayMetadata(
      status: Completed,
      manifestCid: manifestCid,
      totalBlocks: 4,
      totalSize: 1024,
      expiry: now + 3600,
      kind: DatasetOverlay,
    )
    (await datasetStore.setOverlayMetadata(treeCid, meta)).tryGet()

    let (present, total) = (await dm.getProgress(manifestCid)).tryGet()
    check:
      total == 4
      present == 4

  test "getProgress should count partial downloads correctly":
    let
      treeCid = Cid.example
      manifestBlk = createManifestBlock(treeCid, blocksCount = 4, blockSize = 256)
      manifestCid = manifestBlk.cid

    var blocks: seq[bt.Block] = @[]
    for i in 0 ..< 2:
      blocks.add(bt.Block.example(size = 256))

    (await mockStore.putBlock(manifestBlk)).tryGet()
    for i, blk in blocks:
      (await mockStore.putBlock(blk)).tryGet()
      (await mockStore.putCidAndProof(treeCid, i, blk.cid, ArchivistProof())).tryGet()

    let meta = OverlayMetadata(
      status: Downloading,
      manifestCid: manifestCid,
      totalBlocks: 4,
      totalSize: 1024,
      expiry: now + 3600,
      kind: DatasetOverlay,
    )
    (await datasetStore.setOverlayMetadata(treeCid, meta)).tryGet()

    let (present, total) = (await dm.getProgress(manifestCid)).tryGet()
    check:
      total == 4
      present == 2

  test "deleteOverlay should remove metadata":
    let
      treeCid = Cid.example
      manifestBlk = createManifestBlock(treeCid, blocksCount = 2, blockSize = 256)
      manifestCid = manifestBlk.cid

    (await mockStore.putBlock(manifestBlk)).tryGet()
    let meta = OverlayMetadata(
      status: Completed,
      manifestCid: manifestCid,
      totalBlocks: 2,
      totalSize: 512,
      expiry: now + 3600,
      kind: DatasetOverlay,
    )
    (await datasetStore.setOverlayMetadata(treeCid, meta)).tryGet()

    (await dm.deleteOverlay(manifestCid)).tryGet()

    let result = await datasetStore.getOverlayMetadata(treeCid)
    check result.isErr

  test "deleteDataset should be alias for deleteOverlay":
    let
      treeCid = Cid.example
      manifestBlk = createManifestBlock(treeCid, blocksCount = 2, blockSize = 256)
      manifestCid = manifestBlk.cid

    (await mockStore.putBlock(manifestBlk)).tryGet()
    let meta = OverlayMetadata(
      status: Completed,
      manifestCid: manifestCid,
      totalBlocks: 2,
      totalSize: 512,
      expiry: now + 3600,
      kind: DatasetOverlay,
    )
    (await datasetStore.setOverlayMetadata(treeCid, meta)).tryGet()

    (await dm.deleteDataset(manifestCid)).tryGet()

    let result = await datasetStore.getOverlayMetadata(treeCid)
    check result.isErr

  test "cancelDownload should fail when no active download":
    let
      treeCid = Cid.example
      manifestBlk = createManifestBlock(treeCid, blocksCount = 2, blockSize = 256)
      manifestCid = manifestBlk.cid

    (await mockStore.putBlock(manifestBlk)).tryGet()

    let result = await dm.cancelDownload(manifestCid)
    check result.isErr

  test "getProgress should fail when overlay not found":
    let
      treeCid = Cid.example
      manifestBlk = createManifestBlock(treeCid, blocksCount = 2, blockSize = 256)
      manifestCid = manifestBlk.cid

    (await mockStore.putBlock(manifestBlk)).tryGet()

    let result = await dm.getProgress(manifestCid)
    check result.isErr
