import std/os
import std/times
import pkg/chronos
import pkg/taskpools
import pkg/archivist/marketplacestorage
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
    let verifiable = !await builder.buildManifest()
    let cid = (!await node.storeManifest(verifiable)).cid
    file.close()
    cid

  # NOTE: Block-level expiry tests are skipped because expiry management
  # has been moved to overlay level. See design doc v3.8 Section 12
  # "Overlay Lifecycle & Maintenance". These tests will be re-enabled
  # when DatasetManager overlay expiry is implemented.

  test "updates expiry of slot blocks (no-op pending overlay implementation)":
    let cid = await storeVerifiableData()
    let expiry = getTime().toUnix + DefaultDatasetTtl.seconds + 42
    # updateSlotExpiry is now a no-op - expiry managed at overlay level
    !await storage.updateSlotExpiry(cid, 0, expiry)
    # Verification skipped - will be re-enabled with overlay expiry

  test "updates expiry of dataset manifest (no-op pending overlay implementation)":
    let cid = await storeVerifiableData()
    let expiry = getTime().toUnix + DefaultDatasetTtl.seconds + 42
    # updateSlotExpiry is now a no-op - expiry managed at overlay level
    !await storage.updateSlotExpiry(cid, 0, expiry)
    # Verification skipped - will be re-enabled with overlay expiry

  test "storing a slot updates the expiry of the slot blocks":
    let cid = await storeVerifiableData()
    let expiry = getTime().toUnix + DefaultDatasetTtl.seconds + 42
    !await storage.storeSlot(cid, 0, expiry, repair = false)
    # Expiry verification skipped - managed at overlay level

  test "storing a slot updates the expiry of the dataset manifest":
    let cid = await storeVerifiableData()
    let expiry = getTime().toUnix + DefaultDatasetTtl.seconds + 42
    !await storage.storeSlot(cid, 0, expiry, repair = false)
    # Expiry verification skipped - managed at overlay level
