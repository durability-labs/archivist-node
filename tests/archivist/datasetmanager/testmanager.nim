import std/sequtils

import pkg/chronos
import pkg/kvstore/sql
import pkg/questionable
import pkg/questionable/results

import pkg/archivist/blocktype as bt
import pkg/archivist/clock
import pkg/archivist/datasetmanager/manager
import pkg/archivist/datasetmanager/store
import pkg/archivist/datasetmanager/types

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
    metaStore = SQLiteKVStore.new(Memory).tryGet()
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

    (await dm.setOverlayMetadata(manifestCid, meta)).tryGet()

    let retrieved = (await dm.getOverlayMetadata(manifestCid)).tryGet()

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
      manifestCid = Cid.example
      meta1 = OverlayMetadata(
        status: Pending,
        manifestCid: manifestCid,
        totalBlocks: 50,
        totalSize: 512,
        expiry: now + 1800,
        kind: DatasetOverlay,
      )

    (await dm.setOverlayMetadata(manifestCid, meta1)).tryGet()

    var meta2 = meta1
    meta2.status = Completed

    (await dm.setOverlayMetadata(manifestCid, meta2)).tryGet()

    let retrieved = (await dm.getOverlayMetadata(manifestCid)).tryGet()
    check retrieved.status == Completed

  test "Should delete overlay metadata":
    let
      manifestCid = Cid.example
      meta = OverlayMetadata(
        status: Completed,
        manifestCid: manifestCid,
        totalBlocks: 10,
        totalSize: 100,
        expiry: now + 7200,
        kind: DatasetOverlay,
      )

    (await dm.setOverlayMetadata(manifestCid, meta)).tryGet()
    (await dm.deleteOverlayMetadata(manifestCid)).tryGet()

    let result = await dm.getOverlayMetadata(manifestCid)
    check result.isErr

  test "Should list all datasets":
    let
      cid1 = Cid.example
      cid2 = Cid.example
      cid3 = Cid.example

    for cid in [cid1, cid2, cid3]:
      let meta = OverlayMetadata(
        status: Completed,
        manifestCid: cid,
        totalBlocks: 10,
        totalSize: 100,
        expiry: now + 3600,
        kind: DatasetOverlay,
      )
      (await dm.setOverlayMetadata(cid, meta)).tryGet()

    let datasets = (await dm.listDatasets()).tryGet()
    check datasets.len == 3

  test "Should list datasets filtered by state":
    let
      cidCompleted1 = Cid.example
      cidCompleted2 = Cid.example
      cidDownloading = Cid.example

    (
      await dm.setOverlayMetadata(
        cidCompleted1,
        OverlayMetadata(
          status: Completed,
          manifestCid: cidCompleted1,
          totalBlocks: 10,
          totalSize: 100,
          expiry: now + 3600,
          kind: DatasetOverlay,
        ),
      )
    ).tryGet()

    (
      await dm.setOverlayMetadata(
        cidCompleted2,
        OverlayMetadata(
          status: Completed,
          manifestCid: cidCompleted2,
          totalBlocks: 20,
          totalSize: 200,
          expiry: now + 3600,
          kind: DatasetOverlay,
        ),
      )
    ).tryGet()

    (
      await dm.setOverlayMetadata(
        cidDownloading,
        OverlayMetadata(
          status: Downloading,
          manifestCid: cidDownloading,
          totalBlocks: 30,
          totalSize: 300,
          expiry: now + 3600,
          kind: DatasetOverlay,
        ),
      )
    ).tryGet()

    let
      completedDatasets = (await dm.listDatasetsInState(Completed)).tryGet()
      downloadingDatasets = (await dm.listDatasetsInState(Downloading)).tryGet()
      pendingDatasets = (await dm.listDatasetsInState(Pending)).tryGet()

    check:
      completedDatasets.len == 2
      downloadingDatasets.len == 1
      pendingDatasets.len == 0

  test "Should store slot overlay with parent reference":
    let
      parentCid = Cid.example
      slotManifestCid = Cid.example
      meta = OverlayMetadata(
        status: Completed,
        manifestCid: slotManifestCid,
        totalBlocks: 5,
        totalSize: 50,
        expiry: now + 3600,
        kind: SlotOverlay,
        parentTreeCid: parentCid.some,
      )

    (await dm.setOverlayMetadata(slotManifestCid, meta)).tryGet()

    let retrieved = (await dm.getOverlayMetadata(slotManifestCid)).tryGet()

    check:
      retrieved.kind == SlotOverlay
      retrieved.parentTreeCid.isSome
      retrieved.parentTreeCid.get == parentCid
