import std/os
import std/options
import std/times
import std/importutils

import pkg/chronos
import pkg/datastore
import pkg/datastore/typedds
import pkg/questionable
import pkg/questionable/results
import pkg/stint
import pkg/taskpools

import pkg/nitro
import pkg/archivistdht/discv5/protocol as discv5

import pkg/archivist/logutils
import pkg/archivist/stores
import pkg/archivist/clock
import pkg/archivist/contracts
import pkg/archivist/systemclock
import pkg/archivist/blockexchange
import pkg/archivist/chunker
import pkg/archivist/slots
import pkg/archivist/manifest
import pkg/archivist/discovery
import pkg/archivist/erasure
import pkg/archivist/blocktype as bt
import pkg/archivist/stores/repostore/coders
import pkg/archivist/utils/asynciter
import pkg/archivist/indexingstrategy

import pkg/archivist/node {.all.}

import ../../asynctest
import ../../examples
import ../helpers
import ../helpers/mockmarket
import ../helpers/mockclock

import ./helpers

privateAccess(ArchivistNodeRef) # enable access to private fields

asyncchecksuite "Test Node - Host contracts":
  setupAndTearDown()

  var
    sales: Sales
    purchasing: Purchasing
    manifest: Manifest
    manifestCidStr: string
    manifestCid: Cid
    market: MockMarket
    builder: Poseidon2Builder
    verifiable: Manifest
    verifiableBlock: bt.Block
    protected: Manifest

  setup:
    # Setup Host Contracts and dependencies
    market = MockMarket.new()
    sales = Sales.new(market, clock, localStore)

    node.contracts = (
      none ClientInteractions,
      some HostInteractions.new(clock, sales),
      none ValidatorInteractions,
    )

    await node.start()

    # Populate manifest in local store
    manifest = await storeDataGetManifest(localStore, chunker)
    let
      manifestBlock =
        bt.Block.new(manifest.encode().tryGet(), codec = ManifestCodec).tryGet()
      erasure = Erasure.new(store, leoEncoderProvider, leoDecoderProvider, Taskpool.new)

    manifestCid = manifestBlock.cid

    (await localStore.putBlock(manifestBlock)).tryGet()

    protected = (await erasure.encode(manifest, 3, 2)).tryGet()
    builder = Poseidon2Builder.new(localStore, protected).tryGet()
    verifiable = (await builder.buildManifest()).tryGet()
    verifiableBlock =
      bt.Block.new(verifiable.encode().tryGet(), codec = ManifestCodec).tryGet()

    (await localStore.putBlock(verifiableBlock)).tryGet()

  test "onExpiryUpdate callback is set":
    check sales.onExpiryUpdate.isSome

  test "onExpiryUpdate callback":
    let
      # The blocks have set default TTL, so in order to update it we have to have larger TTL
      expectedExpiry: SecondsSince1970 = clock.now + DefaultBlockTtl.seconds + 11123
      expiryUpdateCallback = !sales.onExpiryUpdate

    (await expiryUpdateCallback(manifestCid, expectedExpiry)).tryGet()

    for index in 0 ..< manifest.blocksCount:
      let
        blk = (await localStore.getBlock(manifest.treeCid, index)).tryGet
        key = (createBlockExpirationMetadataKey(blk.cid)).tryGet
        bytes = (await localStoreMetaDs.get(key)).tryGet
        blkMd = BlockMetadata.decode(bytes).tryGet

      check blkMd.expiry == expectedExpiry

  test "onStore callback is set":
    check sales.onStore.isSome

  test "onStore callback":
    let onStore = !sales.onStore
    var request = StorageRequest.example
    request.content.cid = verifiableBlock.cid
    let expiry = (getTime() + DefaultBlockTtl.toTimesDuration + 1.hours).toUnix
    var fetchedBytes: uint = 0

    let onBlocks = proc(
        blocks: seq[bt.Block]
    ): Future[?!void] {.async: (raises: [CancelledError]).} =
      for blk in blocks:
        fetchedBytes += blk.data.len.uint
      return success()

    (await onStore(request, expiry, 1.uint64, onBlocks, isRepairing = false)).tryGet()
    check fetchedBytes == 12 * DefaultBlockSize.uint

    let indexer = verifiable.verifiableStrategy.init(
      0, verifiable.blocksCount - 1, verifiable.numSlots
    )

    for index in indexer.getIndices(1):
      let
        blk = (await localStore.getBlock(verifiable.treeCid, index)).tryGet
        key = (createBlockExpirationMetadataKey(blk.cid)).tryGet
        bytes = (await localStoreMetaDs.get(key)).tryGet
        blkMd = BlockMetadata.decode(bytes).tryGet

      check blkMd.expiry == expiry
