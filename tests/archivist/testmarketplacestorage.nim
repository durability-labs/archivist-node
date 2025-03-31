import std/os
import std/times
import pkg/chronos
import pkg/taskpools
import pkg/datastore/typedds
import pkg/archivist/marketplace
import pkg/archivist/marketplacestorage
import pkg/archivist/marketplace/timestamps
import pkg/archivist/node
import pkg/archivist/chunker
import pkg/archivist/erasure
import pkg/archivist/slots
import pkg/archivist/stores
import pkg/archivist/indexingstrategy
import ../asynctest
import ./node/tempnode
import ./helpers

suite "Marketplace storage interface implementation":
  var storage: MarketplaceStorage
  var temporary: TemporaryNode
  var verifiable: Manifest

  setup:
    temporary = await TemporaryNode.create()
    storage = MarketplaceStorage.new(temporary.node, temporary.localStore)

  teardown:
    await temporary.destroy()

  proc storeVerifiableData(): Future[Cid] {.async.} =
    let node = temporary.node
    let localStore = temporary.localStore
    let networkStore = temporary.networkStore
    let path = currentSourcePath().parentDir
    let filename = path / ".." / "fixtures" / "test.jpg"
    let file = open(filename)
    let chunker = FileChunker.new(file, chunkSize = DefaultBlockSize)
    let encoder = leoEncoderProvider
    let decoder = leoDecoderProvider
    let taskpool = TaskPool.new()
    let erasure = Erasure.new(networkStore, encoder, decoder, taskpool)
    let manifest = await storeDataGetManifest(localStore, chunker)
    let protected = !await erasure.encode(manifest, 3, 2)
    let builder = !Poseidon2Builder.new(localStore, protected)
    verifiable = !await builder.buildManifest()
    let cid = (!await node.storeManifest(verifiable)).cid
    file.close()
    cid

  proc checkBlockExpiry(cid: Cid, expiry: int64) {.async.} =
    let localStore = temporary.localStore
    let key = !createBlockExpirationMetadataKey(cid)
    let metadata = !await get[BlockMetaData](localStore.metaDs, key)
    check metadata.expiry == expiry

  proc checkSlotExpiry(cid: Cid, slotIndex: uint64, expiry: int64) {.async.} =
    let node = temporary.node
    let localStore = temporary.localStore
    let manifest = !await node.fetchManifest(cid)
    let strategy = manifest.verifiableStrategy
    let indexer = strategy.init(0, manifest.blocksCount - 1, manifest.numSlots)
    for index in indexer.getIndices(slotIndex.int):
      let blockCid = !await localStore.getCid(manifest.treeCid, index)
      await checkBlockExpiry(blockCid, expiry)

  test "updates expiry of slot blocks":
    let cid = await storeVerifiableData()
    let expiry = getTime().toUnix + DefaultBlockTtl.seconds + 42
    !await storage.updateSlotExpiry(cid, 0, StorageTimestamp.init(expiry))
    await checkSlotExpiry(cid, 0, expiry)

  test "updates expiry of dataset manifest":
    let cid = await storeVerifiableData()
    let expiry = getTime().toUnix + DefaultBlockTtl.seconds + 42
    !await storage.updateSlotExpiry(cid, 0, StorageTimestamp.init(expiry))
    await checkBlockExpiry(cid, expiry)

  test "rejects manifest with incorrect slotSize":
    let cid = await storeVerifiableData()
    let expiry = getTime().toUnix + DefaultBlockTtl.seconds + 42
    let response =
      await storage.storeSlot(cid, 0, verifiable.slotSize.uint64 - 1, expiry, false)
    check response.isFailure
    check response.error.msg ==
      "Received manifest slotSize does not match storage request slotSize"

  test "storing a slot updates the expiry of the slot blocks":
    let cid = await storeVerifiableData()
    let expiry = getTime().toUnix + DefaultBlockTtl.seconds + 42
    !await storage.storeSlot(cid, 0, verifiable.slotSize.uint64, StorageTimestamp.init(expiry), false)
    await checkSlotExpiry(cid, 0, expiry)

  test "storing a slot updates the expiry of the dataset manifest":
    let cid = await storeVerifiableData()
    let expiry = getTime().toUnix + DefaultBlockTtl.seconds + 42
    !await storage.storeSlot(cid, 0, verifiable.slotSize.uint64, StorageTimestamp.init(expiry), false)
    await checkBlockExpiry(cid, expiry)
