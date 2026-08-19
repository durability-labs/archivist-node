import std/sequtils
import std/tables

import pkg/chronos
import pkg/kvstore
import pkg/questionable
import pkg/taskpools

import pkg/archivist/rng
import pkg/archivist/stores
import pkg/archivist/blockexchange
import pkg/archivist/chunker
import pkg/archivist/blocktype as bt
import pkg/archivist/blockexchange/engine
import pkg/archivist/manifest
import pkg/archivist/merkletree

import ../../../asynctest
import ../../helpers
import ../../helpers/mockdiscovery
import ../../examples

proc asBlock(m: Manifest): bt.Block =
  let mdata = m.encode().tryGet()
  bt.Block.new(data = mdata, codec = ManifestCodec).tryGet()

# Helper: a peer selector that always returns Requeue with a delay
proc alwaysRequeue(delay: Duration = 0.seconds): PeerSelectorHandler =
  proc selector(
      address: BlockAddress
  ): Future[?!PeerSelection] {.async: (raises: [CancelledError]), gcsafe.} =
    success PeerSelection(kind: PeerSelectionKind.Requeue, delay: delay)

  return selector

asyncchecksuite "Test Discovery Engine":
  let chunker = RandomChunker.new(Rng.instance(), size = 4096, chunkSize = 256)

  var
    blocks: seq[bt.Block]
    manifest: Manifest
    tree: ArchivistTree
    manifestBlock: bt.Block
    switch: Switch
    peerStore: PeerCtxStore
    blockDiscovery: MockDiscovery
    pendingBlocks: PendingBlocksManager
    network: BlockExcNetwork
    tp: Taskpool

  setup:
    tp = Taskpool.new(num_threads = 4)
    while true:
      let chunk = (await chunker.getBytes()).tryGet()
      if chunk.len <= 0:
        break

      blocks.add(bt.Block.new(chunk).tryGet())

    (manifest, tree) = makeManifestAndTree(blocks).tryGet()
    manifestBlock = manifest.asBlock()
    blocks.add(manifestBlock)

    switch = SwitchBuilder
      .new()
      .withNoise()
      .withMplex(5.minutes, 5.minutes)
      .withTcpTransport({ServerFlags.ReuseAddr})
      .withAddresses(@[MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()])
      .build()
    network = BlockExcNetwork.new(switch)
    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new()
    blockDiscovery = MockDiscovery.new()

  teardown:
    tp.shutdown()

  test "Should Query Wants":
    var
      localStore = RepoStore.new(
        SQLiteKVStore.new(SqliteMemory, tp).tryGet(),
        SQLiteKVStore.new(SqliteMemory, tp).tryGet(),
      )
      discoveryEngine = DiscoveryEngine.new(
        localStore,
        peerStore,
        network,
        blockDiscovery,
        pendingBlocks,
        discoveryLoopSleep = 100.millis,
      )
      wants: seq[BlockHandle]

    pendingBlocks.getPeerForBlock = alwaysRequeue(30.seconds)
    await pendingBlocks.start()
    wants = blocks.mapIt(pendingBlocks.getWantHandle(it.cid))
    blockDiscovery.findBlockProvidersHandler = proc(
        d: MockDiscovery, cid: Cid
    ): Future[seq[SignedPeerRecord]] {.async: (raises: [CancelledError]).} =
      await pendingBlocks.resolve(
        blocks.filterIt(it.cid == cid).mapIt(
          BlockDelivery(blk: it, address: it.address)
        )
      )

    await discoveryEngine.start()
    await allFuturesThrowing(allFinished(wants)).wait(100.millis)
    await discoveryEngine.stop()
    await pendingBlocks.stop()

  test "Should queue discovery request":
    var
      localStore = RepoStore.new(
        SQLiteKVStore.new(SqliteMemory, tp).tryGet(),
        SQLiteKVStore.new(SqliteMemory, tp).tryGet(),
      )
      discoveryEngine = DiscoveryEngine.new(
        localStore,
        peerStore,
        network,
        blockDiscovery,
        pendingBlocks,
        discoveryLoopSleep = 100.millis,
      )
      want = newFuture[void]()

    blockDiscovery.findBlockProvidersHandler = proc(
        d: MockDiscovery, cid: Cid
    ): Future[seq[SignedPeerRecord]] {.async: (raises: [CancelledError]).} =
      check cid == blocks[0].cid
      if not want.finished:
        want.complete()

    await discoveryEngine.start()
    discoveryEngine.queueFindBlocksReq(@[blocks[0].cid])
    await want.wait(100.millis)
    await discoveryEngine.stop()

  test "Should not request more than minPeersPerBlock":
    var
      localStore = RepoStore.new(
        SQLiteKVStore.new(SqliteMemory, tp).tryGet(),
        SQLiteKVStore.new(SqliteMemory, tp).tryGet(),
      )
      minPeers = 2
      discoveryEngine = DiscoveryEngine.new(
        localStore,
        peerStore,
        network,
        blockDiscovery,
        pendingBlocks,
        discoveryLoopSleep = 5.minutes,
        minPeersPerBlock = minPeers,
      )
      want = newAsyncEvent()

    var pendingCids = newSeq[Cid]()
    blockDiscovery.findBlockProvidersHandler = proc(
        d: MockDiscovery, cid: Cid
    ): Future[seq[SignedPeerRecord]] {.async: (raises: [CancelledError]).} =
      check cid in pendingCids
      pendingCids.keepItIf(it != cid)
      check peerStore.len < minPeers
      var peerCtx = BlockExcPeerCtx.new(PeerId.example)

      let address = BlockAddress(leaf: false, cid: cid)

      peerCtx.blocks[address] = Presence(address: address)
      peerStore.add(peerCtx)
      want.fire()

    await discoveryEngine.start()
    var idx = 0
    while peerStore.len < minPeers:
      let cid = blocks[idx].cid
      inc idx
      pendingCids.add(cid)
      discoveryEngine.queueFindBlocksReq(@[cid])
      await want.wait()
      want.clear()

    check peerStore.len == minPeers
    await discoveryEngine.stop()

  test "Should not request if there is already an inflight discovery request":
    var
      localStore = RepoStore.new(
        SQLiteKVStore.new(SqliteMemory, tp).tryGet(),
        SQLiteKVStore.new(SqliteMemory, tp).tryGet(),
      )
      discoveryEngine = DiscoveryEngine.new(
        localStore,
        peerStore,
        network,
        blockDiscovery,
        pendingBlocks,
        discoveryLoopSleep = 100.millis,
        concurrentDiscReqs = 2,
      )
      reqs = Future[void].Raising([CancelledError]).init()
      count = 0

    blockDiscovery.findBlockProvidersHandler = proc(
        d: MockDiscovery, cid: Cid
    ): Future[seq[SignedPeerRecord]] {.async: (raises: [CancelledError]).} =
      check cid == blocks[0].cid
      if count > 0:
        check false
      count.inc

      await reqs # queue the request

    await discoveryEngine.start()
    discoveryEngine.queueFindBlocksReq(@[blocks[0].cid])
    await sleepAsync(200.millis)

    discoveryEngine.queueFindBlocksReq(@[blocks[0].cid])
    await sleepAsync(200.millis)

    reqs.complete()
    await discoveryEngine.stop()

  test "Should back off failed discovery requests":
    var
      localStore = RepoStore.new(
        SQLiteKVStore.new(SqliteMemory, tp).tryGet(),
        SQLiteKVStore.new(SqliteMemory, tp).tryGet(),
      )
      discoveryEngine = DiscoveryEngine.new(
        localStore,
        peerStore,
        network,
        blockDiscovery,
        pendingBlocks,
        discoveryLoopSleep = 100.millis,
      )
      calls = 0

    blockDiscovery.findBlockProvidersHandler = proc(
        d: MockDiscovery, cid: Cid
    ): Future[seq[SignedPeerRecord]] {.async: (raises: [CancelledError]).} =
      calls.inc
      # empty result is a failed discovery

    pendingBlocks.getPeerForBlock = alwaysRequeue(30.seconds)
    await pendingBlocks.start()
    discard pendingBlocks.getWantHandle(blocks[0].cid)
    check toSeq(pendingBlocks.wantListBlockCids).len == 1

    await discoveryEngine.start()
    discoveryEngine.queueFindBlocksReq(@[blocks[0].cid])
    await sleepAsync(1.seconds)
    check calls == 1

    # Backoff (3s) has elapsed, the re-queued want is processed again
    await sleepAsync(2.seconds + 300.millis)
    check calls == 2

    # Backoff doubles (3s -> 6s), so the third call must not happen yet
    await sleepAsync(1.seconds)
    check calls == 2

    await discoveryEngine.stop()
    await pendingBlocks.stop()

  test "Should rediscover immediately once a block leaves the want list":
    var
      localStore = RepoStore.new(
        SQLiteKVStore.new(SqliteMemory, tp).tryGet(),
        SQLiteKVStore.new(SqliteMemory, tp).tryGet(),
      )
      discoveryEngine = DiscoveryEngine.new(
        localStore,
        peerStore,
        network,
        blockDiscovery,
        pendingBlocks,
        discoveryLoopSleep = 100.millis,
      )
      calls = 0

    blockDiscovery.findBlockProvidersHandler = proc(
        d: MockDiscovery, cid: Cid
    ): Future[seq[SignedPeerRecord]] {.async: (raises: [CancelledError]).} =
      calls.inc
      # empty result is a failed discovery

    pendingBlocks.getPeerForBlock = alwaysRequeue(30.seconds)
    await pendingBlocks.start()
    discard pendingBlocks.getWantHandle(blocks[0].cid)
    await discoveryEngine.start()

    discoveryEngine.queueFindBlocksReq(@[blocks[0].cid])
    await sleepAsync(1.seconds)
    check calls == 1

    # Second failure grows the backoff to 6s
    discoveryEngine.queueFindBlocksReq(@[blocks[0].cid])
    await sleepAsync(3.seconds + 300.millis)
    check calls == 2

    # Resolve the block - it leaves the want list; its backoff must be pruned
    await pendingBlocks.resolve(BlockAddress.init(blocks[0].cid), blocks[0])
    await sleepAsync(500.millis) # prune runs every discoveryLoopSleep (100ms)

    # Re-request the same cid - discovery must fire without the stale 6s wait
    discard pendingBlocks.getWantHandle(blocks[0].cid)
    discoveryEngine.queueFindBlocksReq(@[blocks[0].cid])
    await sleepAsync(1.seconds)
    check calls == 3

    await discoveryEngine.stop()
    await pendingBlocks.stop()
