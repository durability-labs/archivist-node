import std/options
import std/times

import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/stint

import pkg/archivist/stores
import pkg/archivist/marketplace
import pkg/archivist/marketplace/contracts
import pkg/archivist/slots
import pkg/archivist/manifest
import pkg/archivist/erasure
import pkg/archivist/blocktype as bt
import pkg/chronos/transports/stream

import pkg/archivist/node

import ../../asynctest
import ../../examples
import ../helpers

import ./helpers
import ../helpers/nodeutils

proc fetchStreamData(stream: LPStream, datasetSize: int): Future[seq[byte]] {.async.} =
  var buf = newSeq[byte](datasetSize)
  await stream.readExactly(addr buf[0], datasetSize)
  buf

proc flatten[T](s: seq[seq[T]]): seq[T] =
  var t = newSeq[T](0)
  for ss in s:
    t &= ss
  return t

suite "Test Node - Slot Repair":
  let
    numNodes = 12
    config = NodeConfig(
      useRepoStore: true,
      findFreePorts: true,
      createFullNode: true,
      enableBootstrap: true,
    )
  var
    manifest: Manifest
    builder: Poseidon2Builder
    verifiable: Manifest
    verifiableBlock: bt.Block
    protected: Manifest
    cluster: NodesCluster

    nodes: seq[ArchivistNodeRef]
    localStores: seq[RepoStore]

  setup:
    cluster = generateNodes(numNodes, config = config)
    nodes = cluster.nodes
    localStores = cluster.localStores
    await connectNodes(cluster)

  teardown:
    await cluster.cleanup()
    localStores = @[]
    nodes = @[]

  test "repair slots (2,1)":
    let
      expiry = (getTime() + DefaultOverlayTtl.toTimesDuration + 1.hours).toUnix
      numBlocks = 5
      datasetSize = numBlocks * DefaultBlockSize.int
      ecK = 2
      ecM = 1
      localStore = localStores[0]
      store = nodes[0].blockStore
      blocks = (
        await makeRandomBlocks(datasetSize = datasetSize, blockSize = DefaultBlockSize)
      ).tryGet
      data = (
        block:
          collect(newSeq):
            for blk in blocks:
              blk.data
      ).flatten()
    check blocks.len == numBlocks

    # Populate manifest in local store
    manifest = (await storeDataGetManifest(localStore, blocks)).tryGet()
    let
      manifestBlock =
        bt.Block.new(manifest.encode().tryGet(), codec = ManifestCodec).tryGet()
      erasure = Erasure.new(
        store, localStore, leoEncoderProvider, leoDecoderProvider, cluster.taskpool
      )

    (await localStore.putBlock(manifestBlock)).tryGet()

    protected = (await erasure.encode(manifest, ecK, ecM)).tryGet()
    builder = Poseidon2Builder.new(store, localStore, protected).tryGet()
    verifiable = (await builder.buildManifest()).tryGet()
    verifiableBlock =
      bt.Block.new(verifiable.encode().tryGet(), codec = ManifestCodec).tryGet()

    # Populate protected manifest in local store
    (await localStore.putBlock(verifiableBlock)).tryGet()

    let cid = verifiableBlock.cid

    proc storeSlot(
        node: ArchivistNodeRef, slotIndex: uint64, repair: bool
    ): Future[?!void] =
      return node.storeSlot(cid, slotIndex, verifiable.slotSize.uint64, expiry, repair)

    for i in 0 ..< protected.numSlots.uint64:
      (await nodes[i + 1].storeSlot(i, repair = false)).tryGet()

    await nodes[0].switch.stop() # acts as client
    await nodes[1].switch.stop() # slot 0 missing now

    # repair missing slot
    (await nodes[4].storeSlot(0.uint64, repair = true)).tryGet()

    await nodes[2].switch.stop() # slot 1 missing now

    (await nodes[5].storeSlot(1.uint64, repair = true)).tryGet()

    await nodes[3].switch.stop() # slot 2 missing now

    (await nodes[6].storeSlot(2.uint64, repair = true)).tryGet()

    await nodes[4].switch.stop() # slot 0 missing now

    # repair missing slot from repaired slots
    (await nodes[7].storeSlot(0.uint64, repair = true)).tryGet()

    await nodes[5].switch.stop() # slot 1 missing now

    # repair missing slot from repaired slots
    (await nodes[8].storeSlot(1.uint64, repair = true)).tryGet()

    await nodes[6].switch.stop() # slot 2 missing now

    # repair missing slot from repaired slots
    (await nodes[9].storeSlot(2.uint64, repair = true)).tryGet()

    let
      stream = (await nodes[10].retrieve(verifiableBlock.cid, local = false)).tryGet()
      expectedData = await fetchStreamData(stream, datasetSize)
    check expectedData.len == data.len
    check expectedData == data

  test "repair slots (3,2)":
    let
      expiry = (getTime() + DefaultOverlayTtl.toTimesDuration + 1.hours).toUnix
      numBlocks = 40
      datasetSize = numBlocks * DefaultBlockSize.int
      ecK = 3
      ecM = 2
      localStore = localStores[0]
      store = nodes[0].blockStore
      blocks = (
        await makeRandomBlocks(datasetSize = datasetSize, blockSize = DefaultBlockSize)
      ).tryGet
      data = (
        block:
          collect(newSeq):
            for blk in blocks:
              blk.data
      ).flatten()
    check blocks.len == numBlocks

    # Populate manifest in local store
    manifest = (await storeDataGetManifest(localStore, blocks)).tryGet()
    let
      manifestBlock =
        bt.Block.new(manifest.encode().tryGet(), codec = ManifestCodec).tryGet()
      erasure = Erasure.new(
        store, localStore, leoEncoderProvider, leoDecoderProvider, cluster.taskpool
      )

    (await localStore.putBlock(manifestBlock)).tryGet()

    protected = (await erasure.encode(manifest, ecK, ecM)).tryGet()
    builder = Poseidon2Builder.new(store, localStore, protected).tryGet()
    verifiable = (await builder.buildManifest()).tryGet()
    verifiableBlock =
      bt.Block.new(verifiable.encode().tryGet(), codec = ManifestCodec).tryGet()

    # Populate protected manifest in local store
    (await localStore.putBlock(verifiableBlock)).tryGet()

    let cid = verifiableBlock.cid

    proc storeSlot(
        node: ArchivistNodeRef, slotIndex: uint64, repair: bool
    ): Future[?!void] =
      return node.storeSlot(cid, slotIndex, verifiable.slotSize.uint64, expiry, repair)

    for i in 0 ..< protected.numSlots.uint64:
      (await nodes[i + 1].storeSlot(i, repair = false)).tryGet()

    await nodes[0].switch.stop() # acts as client
    await nodes[1].switch.stop() # slot 0 missing now
    await nodes[3].switch.stop() # slot 2 missing now

    # repair missing slots
    (await nodes[6].storeSlot(0.uint64, repair = true)).tryGet()
    (await nodes[7].storeSlot(2.uint64, repair = true)).tryGet()

    await nodes[2].switch.stop() # slot 1 missing now
    await nodes[4].switch.stop() # slot 3 missing now

    # repair missing slots from repaired slots
    (await nodes[8].storeSlot(1.uint64, repair = true)).tryGet()
    (await nodes[9].storeSlot(3.uint64, repair = true)).tryGet()

    await nodes[5].switch.stop() # slot 4 missing now

    # repair missing slot from repaired slots
    (await nodes[10].storeSlot(4.uint64, repair = true)).tryGet()

    let
      stream = (await nodes[11].retrieve(verifiableBlock.cid, local = false)).tryGet()
      expectedData = await fetchStreamData(stream, datasetSize)
    check expectedData.len == data.len
    check expectedData == data
