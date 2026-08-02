import std/os
import std/options
import std/math

import pkg/chronos
import pkg/stew/byteutils
import pkg/questionable/results
import pkg/stint
import pkg/poseidon2
import pkg/poseidon2/io
import pkg/taskpools

import pkg/archivistdht/discv5/protocol as discv5

import pkg/archivist/logutils
import pkg/archivist/stores
import pkg/archivist/marketplace/contracts
import pkg/archivist/marketplace/purchasing
import pkg/archivist/marketplace/purchasing/purchase
import pkg/archivist/marketplace/sales
import pkg/archivist/marketplace/availability/store
import pkg/archivist/marketplace/storageinterface
import pkg/archivist/marketplace/node {.all.}
import pkg/archivist/blockexchange
import pkg/archivist/chunker
import pkg/archivist/slots
import pkg/archivist/manifest
import pkg/archivist/discovery
import pkg/archivist/erasure
import pkg/archivist/merkletree
import pkg/archivist/blocktype as bt
import pkg/archivist/rng
import pkg/archivist/utils

import pkg/archivist/node {.all.}

import ../../asynctest
import ../examples
import ../helpers
import ../helpers/mockmarketplace
import ../helpers/mockclock
import ../helpers/mocktimer
import ../slots/helpers

import archivist/stores/maintenance

import ./helpers
import ./tempnode

import std/importutils
privateAccess(MarketplaceNode) # enable access to private fields
privateAccess(ArchivistNode) # enable access to private fields

proc overlayCount(
    repo: RepoStore
): Future[?!int] {.async: (raises: [CancelledError]).} =
  let iter = ?await repo.listOverlays()
  let cids = ?await utils.collect(iter)
  success(cids.len)

proc assertOverlayCompleted(
    repo: RepoStore, treeCid: Cid
): Future[?!void] {.async: (raises: [CancelledError]).} =
  let meta = ?await repo.getOverlay(treeCid)
  if meta.status != Completed:
    return failure("Expected Completed overlay status")
  success()

proc assertRequestOverlaysCompleted(
    repo: RepoStore, request: StorageRequest
): Future[?!void] {.async: (raises: [CancelledError]).} =
  let
    manifestBlk = ?await repo.getBlock(request.content.cid)
    manifest = ?Manifest.decode(manifestBlk)

  if not manifest.verifiable:
    return failure("Expected verifiable manifest in storage request")

  ?await repo.assertOverlayCompleted(manifest.treeCid)
  for slotRoot in manifest.slotRoots:
    ?await repo.assertOverlayCompleted(slotRoot)

  success()

suite "Test Node - Basic":
  var temporary: TemporaryNode
  var node: ArchivistNodeRef
  var localStore: RepoStore
  var networkStore: NetworkStore
  var file: File
  var chunker: Chunker

  setup:
    temporary = await TemporaryNode.create()
    node = temporary.node
    localStore = temporary.localStore
    networkStore = temporary.networkStore
    file = open(currentSourcePath().parentDir / ".." / ".." / "fixtures" / "test.jpg")
    chunker = FileChunker.new(file = file, chunkSize = DefaultBlockSize)

  teardown:
    file.close()
    await temporary.destroy()

  test "Fetch Manifest":
    let
      manifest = (await storeDataGetManifest(localStore, chunker)).tryGet()

      manifestBlock =
        bt.Block.new(manifest.encode().tryGet(), codec = ManifestCodec).tryGet()

    (await localStore.putBlock(manifestBlock)).tryGet()

    let fetched = (await node.fetchManifest(manifestBlock.cid)).tryGet()

    check:
      fetched == manifest

  test "Block Batching":
    let manifest = (await storeDataGetManifest(localStore, chunker)).tryGet()

    for batchSize in 1 .. 12:
      (
        await node.fetchBatched(
          manifest,
          batchSize = batchSize,
          proc(
              blocks: seq[bt.Block]
          ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
            check blocks.len > 0 and blocks.len <= batchSize
            return success(),
        )
      ).tryGet()

  test "Block Batching with corrupted blocks":
    let blocks =
      (await makeRandomBlocks(datasetSize = 64.KiBs.int, blockSize = 64.KiBs)).tryGet
    assert blocks.len == 1

    let blk = blocks[0]

    # corrupt block
    let pos = rng.Rng.instance.rand(blk.data.len - 1)
    blk.data[pos] = byte 0

    let manifest = (await storeDataGetManifest(localStore, blocks)).tryGet()

    let batchSize = manifest.blocksCount
    let res = (
      await node.fetchBatched(
        manifest,
        batchSize = batchSize,
        proc(
            blocks: seq[bt.Block]
        ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
          return failure("Should not be called"),
      )
    )
    check res.isFailure

  test "Should store Data Stream":
    let
      stream = BufferStream.new()
      storeFut = node.store(stream)
        # Let's check that node.store can correctly rechunk these odd chunks
      oddChunker = FileChunker.new(file = file, chunkSize = 1024.NBytes, pad = false)
        # don't pad, so `node.store` gets the correct size

    var original: seq[byte]
    try:
      while (let chunk = (await oddChunker.getBytes()).tryGet; chunk.len > 0):
        original &= chunk
        await stream.pushData(chunk)
    finally:
      await stream.pushEof()
      await stream.close()

    let
      manifestCid = (await storeFut).tryGet()
      manifestBlock = (await localStore.getBlock(manifestCid)).tryGet()
      localManifest = Manifest.decode(manifestBlock).tryGet()

    var data: seq[byte]
    for i in 0 ..< localManifest.blocksCount:
      let blk = (await localStore.getBlock(localManifest.treeCid, i)).tryGet()
      data &= blk.data

    data.setLen(localManifest.datasetSize.int) # truncate data to original size
    check:
      data.len == original.len
      sha256.digest(data) == sha256.digest(original)

  test "Should retrieve a Data Stream":
    let
      manifest = (await storeDataGetManifest(localStore, chunker)).tryGet()
      manifestBlk =
        bt.Block.new(data = manifest.encode().tryGet, codec = ManifestCodec).tryGet()

    (await localStore.putBlock(manifestBlk)).tryGet()
    let data = await ((await node.retrieve(manifestBlk.cid)).tryGet()).drain()

    var storedData: seq[byte]
    for i in 0 ..< manifest.blocksCount:
      let blk = (await localStore.getBlock(manifest.treeCid, i)).tryGet()
      storedData &= blk.data

    storedData.setLen(manifest.datasetSize.int) # truncate data to original size
    check:
      storedData == data

  test "Retrieve One Block":
    let
      testString = "Block 1"
      blk = bt.Block.new(testString.toBytes).tryGet()

    (await localStore.putBlock(blk)).tryGet()
    let stream = (await node.retrieve(blk.cid)).tryGet()
    defer:
      await stream.close()

    var data = newSeq[byte](testString.len)
    await stream.readExactly(addr data[0], data.len)
    check string.fromBytes(data) == testString

  test "Should delete a single block":
    let randomBlock = bt.Block.new("Random block".toBytes).tryGet()
    (await localStore.putBlock(randomBlock)).tryGet()
    check (await randomBlock.cid in localStore) == true

    (await node.delete(randomBlock.cid)).tryGet()
    check (await randomBlock.cid in localStore) == false

  test "Should delete an entire dataset":
    let
      blocks = (await makeRandomBlocks(datasetSize = 2048, blockSize = 256'nb)).tryGet
      manifest = (await storeDataGetManifest(localStore, blocks)).tryGet()
      manifestBlock = (await localStore.storeManifest(manifest)).tryGet()
      manifestCid = manifestBlock.cid

    check await manifestCid in localStore
    for blk in blocks:
      check await blk.cid in localStore

    (await node.delete(manifestCid)).tryGet()

    check not await manifestCid in localStore
    for blk in blocks:
      check not (await blk.cid in localStore)

suite "Test Node - Purchase request":
  var temporary: TemporaryNode
  var node: ArchivistNodeRef
  var localStore: RepoStore
  var networkStore: NetworkStore
  var file: File
  var manifest: Manifest
  var manifestBlock: bt.Block
  var protectedManifestBlock: bt.Block
  var verifiableBlock: bt.Block
  var verifiableMerkleRoot: array[32, byte]

  setup:
    temporary = await TemporaryNode.create()
    node = temporary.node
    localStore = temporary.localStore
    networkStore = temporary.networkStore
    file = open(currentSourcePath().parentDir / ".." / ".." / "fixtures" / "test.jpg")

    let
      chunker = FileChunker.new(file = file, chunkSize = DefaultBlockSize)
      referenceBlocks = (
        await makeRandomBlocks(
          datasetSize = 4 * DefaultBlockSize.int, blockSize = DefaultBlockSize
        )
      ).tryGet()

    manifest = (await storeDataGetManifest(localStore, chunker)).tryGet()
    manifestBlock =
      bt.Block.new(manifest.encode().tryGet(), codec = ManifestCodec).tryGet()

    let
      referenceManifest =
        (await storeDataGetManifest(localStore, referenceBlocks)).tryGet()
      # Reuse the node's own taskpool (visible via privateAccess): creating a
      # second pool on this thread would redirect main-thread spawns through
      # taskpools' threadvar to the newest pool, and shutting that one down
      # would deadlock later spawns on the node's pool.
      erasure = Erasure.new(
        networkStore, localStore, leoEncoderProvider, leoDecoderProvider, node.taskpool
      )
      protected = (await erasure.encode(referenceManifest, 3, 2)).tryGet()
      builder = Poseidon2Builder.new(networkStore, localStore, protected).tryGet()
      verifiable = (await builder.buildManifest(node.taskpool)).tryGet()

    protectedManifestBlock =
      bt.Block.new(protected.encode().tryGet(), codec = ManifestCodec).tryGet()
    verifiableBlock =
      bt.Block.new(verifiable.encode().tryGet(), codec = ManifestCodec).tryGet()
    verifiableMerkleRoot = (verifiable.verifyRoot.fromVerifyCid).tryGet().toBytes

  teardown:
    file.close()
    await temporary.destroy()

  test "Setup purchase request - Basic manifest":
    (await localStore.putBlock(manifestBlock)).tryGet()

    let request = (
      await node.setupRequest(
        cid = manifestBlock.cid,
        nodes = 5,
        tolerance = 2,
        duration = 100'StorageDuration,
        pricePerBytePerSecond = 1'TokensPerSecond,
        proofProbability = 3.u256,
        expiry = 200'StorageDuration,
        collateralPerByte = 1'Tokens,
      )
    ).tryGet()

    let
      requestManifestBlock = (await localStore.getBlock(request.content.cid)).tryGet()
      requestManifest = Manifest.decode(requestManifestBlock).tryGet()
      verifyRoot = (requestManifest.verifyRoot.fromVerifyCid).tryGet().toBytes

    check:
      requestManifest.protected == true
      requestManifest.verifiable == true
      request.content.merkleRoot == verifyRoot
    (await assertRequestOverlaysCompleted(localStore, request)).tryGet()

  test "Setup purchase request - Protected manifest":
    (await localStore.putBlock(protectedManifestBlock)).tryGet()

    let request = (
      await node.setupRequest(
        cid = protectedManifestBlock.cid,
        nodes = 5,
        tolerance = 2,
        duration = 100'StorageDuration,
        pricePerBytePerSecond = 1'TokensPerSecond,
        proofProbability = 3.u256,
        expiry = 200'StorageDuration,
        collateralPerByte = 1'Tokens,
      )
    ).tryGet

    let
      requestManifestBlock = (await localStore.getBlock(request.content.cid)).tryGet()
      requestManifest = Manifest.decode(requestManifestBlock).tryGet()
      verifyRoot = (requestManifest.verifyRoot.fromVerifyCid).tryGet().toBytes

    check:
      requestManifest.protected == true
      requestManifest.verifiable == true
      request.content.merkleRoot == verifyRoot
    (await assertRequestOverlaysCompleted(localStore, request)).tryGet()

  test "Setup purchase request - Verifiable manifest":
    (await localStore.putBlock(verifiableBlock)).tryGet()

    let request = (
      await node.setupRequest(
        cid = verifiableBlock.cid,
        nodes = 5,
        tolerance = 2,
        duration = 100'StorageDuration,
        pricePerBytePerSecond = 1'TokensPerSecond,
        proofProbability = 3.u256,
        expiry = 200'StorageDuration,
        collateralPerByte = 1'Tokens,
      )
    ).tryGet

    check:
      request.content.cid == verifiableBlock.cid
      request.content.merkleRoot == verifiableMerkleRoot
    (await assertRequestOverlaysCompleted(localStore, request)).tryGet()

  test "Setup purchase request - Verifiable manifest fails when ec params mismatch":
    (await localStore.putBlock(verifiableBlock)).tryGet()
    let overlaysBefore = (await overlayCount(localStore)).tryGet()

    let request = (
      await node.setupRequest(
        cid = verifiableBlock.cid,
        nodes = 6,
        tolerance = 2,
        duration = 100'StorageDuration,
        pricePerBytePerSecond = 1'TokensPerSecond,
        proofProbability = 3.u256,
        expiry = 200'StorageDuration,
        collateralPerByte = 1'Tokens,
      )
    )

    check not request.isSuccess
    check request.error.msg ==
      "Attempt to proceed with protected manifest with parameters " &
      "3/2 but required: 4/2"
    check (await overlayCount(localStore)).tryGet() == overlaysBefore

suite "Test Node - Purchase overlay cleanup":
  var temporary: TemporaryNode
  var node: ArchivistNodeRef
  var localStore: RepoStore
  var networkStore: NetworkStore
  var marketplace: MockMarketplace
  var clock: MockClock

  setup:
    temporary = await TemporaryNode.create()
    node = temporary.node
    localStore = temporary.localStore
    networkStore = temporary.networkStore
    clock = MockClock.new()
    marketplace = MockMarketplace.new(clock)

    # Wire up marketplace so node.requestStorage works
    let
      availDs = SQLiteKVStore.new(SqliteMemory, Taskpool.new()).tryGet()
      availability = AvailabilityStore.new(availDs)
    node.marketplace =
      MarketplaceNode(
        clock: clock,
        purchasing: Purchasing.new(marketplace, clock),
        sales: Sales.new(marketplace, clock, availability, StorageInterface()),
      ).some

  teardown:
    node.marketplace = MarketplaceNode.none
    await temporary.destroy()

  test "Should cleanup verifiable and slot overlays when purchase finishes":
    let
      referenceBlocks = (
        await makeRandomBlocks(
          datasetSize = 4 * DefaultBlockSize.int, blockSize = DefaultBlockSize
        )
      ).tryGet()
      referenceManifest =
        (await storeDataGetManifest(localStore, referenceBlocks)).tryGet()
      manifestBlk = (await localStore.storeManifest(referenceManifest)).tryGet()

    # 1 overlay for the original dataset
    check (await overlayCount(localStore)).tryGet() == 1

    let
      quotaBefore = localStore.quotaUsedBytes
      blocksBefore = localStore.totalBlocks

    let purchaseId = (
      await node.requestStorage(
        cid = manifestBlk.cid,
        nodes = 5,
        tolerance = 2,
        duration = 100'StorageDuration,
        pricePerBytePerSecond = 1'TokensPerSecond,
        proofProbability = 3.u256,
        expiry = 200'StorageDuration,
        collateralPerByte = 1'Tokens,
      )
    ).tryGet()

    # Overlays: original + protected/verifiable + 5 slot overlays = 7
    check (await overlayCount(localStore)).tryGet() == 7
    # Erasure coding added blocks, so quota and block count grew
    check localStore.quotaUsedBytes > quotaBefore
    check localStore.totalBlocks > blocksBefore

    # Fulfill the purchase - triggers PurchaseSubmitted -> PurchaseStarted
    check eventually marketplace.requested.len > 0
    let request = marketplace.requested[0]
    let requestEnd = StorageTimestamp.init(clock.now() + 42)
    marketplace.requestEnds[request.id] = requestEnd
    marketplace.emitRequestFulfilled(request.id)

    # Advance clock past request end - triggers PurchaseStarted -> PurchaseFinished
    clock.set(requestEnd.toSecondsSince1970 + 1)

    # Wait for purchase to complete
    let purchasing = node.marketplace .? purchasing
    check eventually purchasing .? getPurchase(purchaseId) .? finished == true.some

    # Wait for cleanup callback to run
    await sleepAsync(500.milliseconds)

    # Original overlay remains, protected/verifiable + 5 slot overlays dropped
    check (await overlayCount(localStore)).tryGet() == 1
    # Quota and block count back to just original data
    check localStore.quotaUsedBytes == quotaBefore
    check localStore.totalBlocks == blocksBefore

  test "Should cleanup verifiable and slot overlays when purchase fails":
    let
      referenceBlocks = (
        await makeRandomBlocks(
          datasetSize = 4 * DefaultBlockSize.int, blockSize = DefaultBlockSize
        )
      ).tryGet()
      referenceManifest =
        (await storeDataGetManifest(localStore, referenceBlocks)).tryGet()
      manifestBlk = (await localStore.storeManifest(referenceManifest)).tryGet()

    # 1 overlay for the original dataset
    check (await overlayCount(localStore)).tryGet() == 1

    let
      quotaBefore = localStore.quotaUsedBytes
      blocksBefore = localStore.totalBlocks

    let purchaseId = (
      await node.requestStorage(
        cid = manifestBlk.cid,
        nodes = 5,
        tolerance = 2,
        duration = 100'StorageDuration,
        pricePerBytePerSecond = 1'TokensPerSecond,
        proofProbability = 3.u256,
        expiry = 200'StorageDuration,
        collateralPerByte = 1'Tokens,
      )
    ).tryGet()

    # Overlays: original + protected/verifiable + 5 slot overlays = 7
    check (await overlayCount(localStore)).tryGet() == 7
    # Erasure coding added blocks, so quota and block count grew
    check localStore.quotaUsedBytes > quotaBefore
    check localStore.totalBlocks > blocksBefore

    # Fulfill the purchase, then fail it
    check eventually marketplace.requested.len > 0
    let request = marketplace.requested[0]
    let requestEnd = StorageTimestamp.init(clock.now() + 42)
    marketplace.requestEnds[request.id] = requestEnd
    marketplace.emitRequestFulfilled(request.id)

    # Wait for PurchaseStarted, then emit failure
    await sleepAsync(100.milliseconds)
    marketplace.emitRequestFailed(request.id)

    # Wait for purchase to complete (with error)
    let purchasing = node.marketplace .? purchasing
    check eventually purchasing .? getPurchase(purchaseId) .? finished == true.some

    # Wait for cleanup callback to run
    await sleepAsync(100.milliseconds)

    # Original overlay remains, protected/verifiable + 5 slot overlays dropped
    check (await overlayCount(localStore)).tryGet() == 1
    # Quota and block count back to just original data
    check localStore.quotaUsedBytes == quotaBefore
    check localStore.totalBlocks == blocksBefore

  test "Should cleanup all manifests and leave repo empty after full lifecycle":
    let
      referenceBlocks = (
        await makeRandomBlocks(
          datasetSize = 4 * DefaultBlockSize.int, blockSize = DefaultBlockSize
        )
      ).tryGet()
      referenceManifest =
        (await storeDataGetManifest(localStore, referenceBlocks)).tryGet()
      manifestBlk = (await localStore.storeManifest(referenceManifest)).tryGet()
      originalTreeCid = referenceManifest.treeCid

    # 1 overlay for the original dataset
    check (await overlayCount(localStore)).tryGet() == 1

    let purchaseId = (
      await node.requestStorage(
        cid = manifestBlk.cid,
        nodes = 5,
        tolerance = 2,
        duration = 100'StorageDuration,
        pricePerBytePerSecond = 1'TokensPerSecond,
        proofProbability = 3.u256,
        expiry = 200'StorageDuration,
        collateralPerByte = 1'Tokens,
      )
    ).tryGet()

    # Overlays: original + protected/verifiable + 5 slot overlays = 7
    check (await overlayCount(localStore)).tryGet() == 7

    # Fulfill the purchase - triggers PurchaseSubmitted -> PurchaseStarted
    check eventually marketplace.requested.len > 0
    let request = marketplace.requested[0]
    let requestEnd = StorageTimestamp.init(clock.now() + 42)
    marketplace.requestEnds[request.id] = requestEnd
    marketplace.emitRequestFulfilled(request.id)

    # Advance clock past request end - triggers PurchaseStarted -> PurchaseFinished
    clock.set(requestEnd.toSecondsSince1970 + 1)

    # Wait for purchase to complete
    let purchasing = node.marketplace .? purchasing
    check eventually purchasing .? getPurchase(purchaseId) .? finished == true.some

    # Wait for cleanup callback to run
    await sleepAsync(100.milliseconds)

    # Only original overlay remains after purchase completes
    check (await overlayCount(localStore)).tryGet() == 1

    # Simulate data expiry: drop the original overlay too
    (await localStore.dropOverlay(originalTreeCid)).tryGet()

    # Everything has been cleaned up - repo is empty
    check (await overlayCount(localStore)).tryGet() == 0
    check localStore.quotaUsedBytes == 0.NBytes
    check localStore.totalBlocks == 0.Natural

suite "Test Node - Maintenance expiry with requestStorage":
  var temporary: TemporaryNode
  var node: ArchivistNodeRef
  var localStore: RepoStore
  var networkStore: NetworkStore
  var marketplace: MockMarketplace
  var clock: MockClock
  var mockTimer: MockTimer
  var maintainer: BlockMaintainer

  setup:
    clock = MockClock.new()
    clock.set(1000)
    temporary = await TemporaryNode.create(clock)
    node = temporary.node
    localStore = temporary.localStore
    networkStore = temporary.networkStore
    marketplace = MockMarketplace.new(clock)
    mockTimer = MockTimer.new()
    maintainer =
      BlockMaintainer.new(localStore, 1.days, timer = mockTimer, clock = clock)

    let
      availDs = SQLiteKVStore.new(SqliteMemory, Taskpool.new()).tryGet()
      availability = AvailabilityStore.new(availDs)
    node.marketplace =
      MarketplaceNode(
        clock: clock,
        purchasing: Purchasing.new(marketplace, clock),
        sales: Sales.new(marketplace, clock, availability, StorageInterface()),
      ).some

  teardown:
    await maintainer.stop()
    node.marketplace = MarketplaceNode.none
    await temporary.destroy()

  test "Should cleanup manifests via maintenance while purchase is in-flight":
    let
      referenceBlocks = (
        await makeRandomBlocks(
          datasetSize = 4 * DefaultBlockSize.int, blockSize = DefaultBlockSize
        )
      ).tryGet()
      referenceManifest =
        (await storeDataGetManifest(localStore, referenceBlocks)).tryGet()
      manifestBlk = (await localStore.storeManifest(referenceManifest)).tryGet()
      originalTreeCid = referenceManifest.treeCid

    let
      quotaOriginal = localStore.quotaUsedBytes
      blocksOriginal = localStore.totalBlocks

    check (await overlayCount(localStore)).tryGet() == 1

    let purchaseId = (
      await node.requestStorage(
        cid = manifestBlk.cid,
        nodes = 5,
        tolerance = 2,
        duration = 100'StorageDuration,
        pricePerBytePerSecond = 1'TokensPerSecond,
        proofProbability = 3.u256,
        expiry = 200'StorageDuration,
        collateralPerByte = 1'Tokens,
      )
    ).tryGet()

    check (await overlayCount(localStore)).tryGet() == 7
    check localStore.quotaUsedBytes > quotaOriginal

    clock.set(1000 + 30 * 24 * 3600 + 100) # well past 30-day TTL

    maintainer.start()
    await mockTimer.invokeCallback()

    check (await overlayCount(localStore)).tryGet() == 0
    check localStore.quotaUsedBytes == 0.NBytes
    check localStore.totalBlocks == 0.Natural
