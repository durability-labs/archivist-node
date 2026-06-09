import pkg/chronos
import pkg/libp2p/routing_record
import pkg/archivistdht/discv5/protocol as discv5
import pkg/kvstore
import pkg/taskpools

import pkg/archivist/blockexchange
import pkg/archivist/stores
import pkg/archivist/chunker
import pkg/archivist/discovery
import pkg/archivist/blocktype as bt
import pkg/archivist/manifest

import ../../../asynctest
import ../../helpers
import ../../helpers/mockdiscovery
import ../../examples

asyncchecksuite "Advertiser":
  var
    blockDiscovery: MockDiscovery
    localStore: BlockStore
    advertiser: Advertiser
    advertised: seq[Cid]
    tp: Taskpool
  let
    manifest = Manifest.new(
      treeCid = Cid.example, blockSize = 123.NBytes, datasetSize = 234.NBytes
    )
    manifestBlk =
      Block.new(data = manifest.encode().tryGet(), codec = ManifestCodec).tryGet()

  setup:
    blockDiscovery = MockDiscovery.new()
    tp = Taskpool.new(num_threads = 4)
    let
      repoDs = SQLiteKVStore.new(SqliteMemory, tp).tryGet()
      metaDs = SQLiteKVStore.new(SqliteMemory, tp).tryGet()
    localStore = RepoStore.new(repoDs, metaDs)

    advertised = newSeq[Cid]()
    blockDiscovery.publishBlockProvideHandler = proc(
        d: MockDiscovery, cid: Cid
    ) {.async: (raises: [CancelledError]), gcsafe.} =
      advertised.add(cid)

    advertiser = Advertiser.new(localStore, blockDiscovery, minAdvertisePeers = 0)

    await advertiser.start()

  teardown:
    await advertiser.stop()
    tp.shutdown()

  proc waitTillQueueEmpty() {.async.} =
    check eventually advertiser.advertiseQueue.len == 0

  test "blockStored should queue manifest Cid for advertising":
    (await localStore.putBlock(manifestBlk)).tryGet()

    await waitTillQueueEmpty()

    check:
      manifestBlk.cid in advertised

  test "blockStored should queue tree Cid for advertising":
    (await localStore.putBlock(manifestBlk)).tryGet()

    await waitTillQueueEmpty()

    check:
      manifest.treeCid in advertised

  test "blockStored should not queue non-manifest non-tree CIDs for discovery":
    let blk = bt.Block.example

    (await localStore.putBlock(blk)).tryGet()

    await waitTillQueueEmpty()

    check:
      blk.cid notin advertised

  test "Should not queue if there is already an inflight advertise request":
    (await localStore.putBlock(manifestBlk)).tryGet()
    (await localStore.putBlock(manifestBlk)).tryGet()

    await waitTillQueueEmpty()

    check eventually advertised.len == 2
    check manifestBlk.cid in advertised
    check manifest.treeCid in advertised

  test "Should advertise existing manifests and their trees":
    let
      newRepoDs = SQLiteKVStore.new(SqliteMemory, tp).tryGet()
      newMetaDs = SQLiteKVStore.new(SqliteMemory, tp).tryGet()
      newStore = RepoStore.new(newRepoDs, newMetaDs)
    (await newStore.putBlock(manifestBlk)).tryGet()

    await advertiser.stop()
    advertiser = Advertiser.new(newStore, blockDiscovery, minAdvertisePeers = 0)
    await advertiser.start()

    check eventually manifestBlk.cid in advertised
    check eventually manifest.treeCid in advertised

  test "Stop should clear onBlockStored callback":
    await advertiser.stop()

    check:
      localStore.onBlockStored.isNone()
