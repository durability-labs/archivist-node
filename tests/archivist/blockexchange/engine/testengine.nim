import std/sequtils
import std/algorithm

import pkg/chronos
import pkg/libp2p/routing_record
import pkg/stew/bitseqs
import pkg/archivistdht/discv5/protocol as discv5

import pkg/kvstore
import pkg/taskpools

import pkg/archivist/rng
import pkg/archivist/blockexchange
import pkg/archivist/stores
import pkg/archivist/chunker
import pkg/archivist/discovery
import pkg/archivist/blocktype
import pkg/archivist/manifest
import pkg/archivist/merkletree
import pkg/archivist/utils/asyncheapqueue

import ../../../asynctest
import ../../helpers

const NopSendWantCancellationsProc = proc(
    id: PeerId, addresses: seq[BlockAddress]
) {.async: (raises: [CancelledError]).} =
  discard

asyncchecksuite "NetworkStore engine basic":
  var
    rng: Rng
    seckey: PrivateKey
    peerId: PeerId
    chunker: Chunker
    blockDiscovery: Discovery
    peerStore: PeerCtxStore
    pendingBlocks: PendingBlocksManager
    blocks: seq[Block]
    done: Future[void]
    manifest: Manifest
    tree: ArchivistTree
    treeCid: Cid
    tp: Taskpool

  setup:
    tp = Taskpool.new(num_threads = 4)
    rng = Rng.instance()
    seckey = PrivateKey.random(rng[]).tryGet()
    peerId = PeerId.init(seckey.getPublicKey().tryGet()).tryGet()
    chunker = RandomChunker.new(Rng.instance(), size = 1024'nb, chunkSize = 256'nb)
    blockDiscovery = Discovery.new()
    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new()

    while true:
      let chunk = (await chunker.getBytes()).tryGet()
      if chunk.len <= 0:
        break

      blocks.add(Block.new(chunk).tryGet())

    (manifest, tree) = makeManifestAndTree(blocks).tryGet()
    treeCid = tree.rootCid.tryGet()
    done = newFuture[void]()

  test "Should send want list to new peers":
    proc sendWantList(
        id: PeerId,
        addresses: seq[BlockAddress],
        priority: int32 = 0,
        cancel: bool = false,
        wantType: WantType = WantType.WantHave,
        full: bool = false,
        sendDontHave: bool = false,
    ) {.async: (raises: [CancelledError]).} =
      check addresses.mapIt($it.cidOrTreeCid).sorted == blocks.mapIt($it.cid).sorted
      done.complete()

    let
      network = BlockExcNetwork(request: BlockExcRequest(sendWantList: sendWantList))
      localStore = RepoStore.new(
        SQLiteKVStore.new(SqliteMemory, tp).tryGet(),
        SQLiteKVStore.new(SqliteMemory, tp).tryGet(),
      )

    # Store blocks with overlay context
    (await localStore.storeBlocksWithOverlay(treeCid, blocks, tree)).tryGet()

    let
      discovery = DiscoveryEngine.new(
        localStore, peerStore, network, blockDiscovery, pendingBlocks
      )
      advertiser = Advertiser.new(localStore, blockDiscovery)
      engine = BlockExcEngine.new(
        localStore, network, discovery, advertiser, peerStore, pendingBlocks
      )

    for b in blocks:
      discard engine.pendingBlocks.getWantHandle(b.cid)

    await engine.setupPeer(peerId)

    await done.wait(100.millis)

  teardown:
    tp.shutdown()

asyncchecksuite "NetworkStore engine handlers":
  var
    rng: Rng
    seckey: PrivateKey
    peerId: PeerId
    chunker: Chunker
    blockDiscovery: Discovery
    peerStore: PeerCtxStore
    pendingBlocks: PendingBlocksManager
    network: BlockExcNetwork
    engine: BlockExcEngine
    discovery: DiscoveryEngine
    advertiser: Advertiser
    peerCtx: BlockExcPeerCtx
    localStore: RepoStore
    blocks: seq[Block]
    manifest: Manifest
    tree: ArchivistTree
    treeCid: Cid
    tp: Taskpool

  setup:
    rng = Rng.instance()
    chunker = RandomChunker.new(rng, size = 1024'nb, chunkSize = 256'nb)

    while true:
      let chunk = (await chunker.getBytes()).tryGet()
      if chunk.len <= 0:
        break

      blocks.add(Block.new(chunk).tryGet())

    (manifest, tree) = makeManifestAndTree(blocks).tryGet()
    treeCid = tree.rootCid.tryGet()
    seckey = PrivateKey.random(rng[]).tryGet()
    peerId = PeerId.init(seckey.getPublicKey().tryGet()).tryGet()
    blockDiscovery = Discovery.new()
    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new()

    tp = Taskpool.new(num_threads = 4)
    localStore = RepoStore.new(
      SQLiteKVStore.new(SqliteMemory, tp).tryGet(),
      SQLiteKVStore.new(SqliteMemory, tp).tryGet(),
    )
    network = BlockExcNetwork()

    discovery =
      DiscoveryEngine.new(localStore, peerStore, network, blockDiscovery, pendingBlocks)

    advertiser = Advertiser.new(localStore, blockDiscovery)

    engine = BlockExcEngine.new(
      localStore, network, discovery, advertiser, peerStore, pendingBlocks
    )

    peerCtx = BlockExcPeerCtx(id: peerId)
    engine.peers.add(peerCtx)

  teardown:
    tp.shutdown()

  test "Should schedule block requests":
    let wantList = makeWantList(blocks.mapIt(it.cid), wantType = WantType.WantBlock)
      # only `wantBlock` are stored in `wantedBlocks`

    proc handler() {.async.} =
      let ctx = await engine.taskQueue.pop()
      check ctx.id == peerId
      # only `wantBlock` scheduled
      check ctx.wantedBlocks.toSeq.mapIt($it.cidOrTreeCid).sorted ==
        blocks.mapIt($it.cid).sorted

    let done = handler()
    await engine.wantListHandler(peerId, wantList)
    await done

  test "Should handle want list":
    let wantList = makeWantList(blocks.mapIt(it.cid))
    var
      done = newFuture[void]()
      received: seq[BlockPresence]

    proc sendPresence(
        peerId: PeerId, presence: seq[BlockPresence]
    ) {.async: (raises: [CancelledError]).} =
      received.add(presence)
      if received.len == wantList.entries.len:
        check received.mapIt($it.address).sorted(cmp[string]) ==
          wantList.entries.mapIt($it.address).sorted(cmp[string])
        done.complete()

    engine.network =
      BlockExcNetwork(request: BlockExcRequest(sendPresence: sendPresence))

    # Store blocks with tree context
    (await localStore.storeBlocksWithOverlay(treeCid, blocks, tree)).tryGet()

    await engine.wantListHandler(peerId, wantList)
    await done

  test "Should handle want list - `dont-have`":
    let wantList = makeWantList(blocks.mapIt(it.cid), sendDontHave = true)
    var
      done = newFuture[void]()
      received: seq[BlockPresence]

    proc sendPresence(
        peerId: PeerId, presence: seq[BlockPresence]
    ) {.async: (raises: [CancelledError]).} =
      received.add(presence)
      if received.len == wantList.entries.len:
        check received.mapIt($it.address).sorted(cmp[string]) ==
          wantList.entries.mapIt($it.address).sorted(cmp[string])
        for p in received:
          check p.`type` == BlockPresenceType.DontHave
        done.complete()

    engine.network =
      BlockExcNetwork(request: BlockExcRequest(sendPresence: sendPresence))

    await engine.wantListHandler(peerId, wantList)
    await done

  test "Should handle want list - `dont-have` some blocks":
    let wantList = makeWantList(blocks.mapIt(it.cid), sendDontHave = true)
    var
      done = newFuture[void]()
      received: seq[BlockPresence]

    proc sendPresence(
        peerId: PeerId, presence: seq[BlockPresence]
    ) {.async: (raises: [CancelledError]).} =
      received.add(presence)
      if received.len == wantList.entries.len:
        for p in received:
          if p.address.cidOrTreeCid != blocks[0].cid and
              p.address.cidOrTreeCid != blocks[1].cid:
            check p.`type` == BlockPresenceType.DontHave
          else:
            check p.`type` == BlockPresenceType.Have

        done.complete()

    engine.network =
      BlockExcNetwork(request: BlockExcRequest(sendPresence: sendPresence))

    # Store first two blocks with tree context
    (await localStore.storeBlocksWithOverlay(treeCid, blocks, tree, @[0, 1])).tryGet()

    await engine.wantListHandler(peerId, wantList)

    await done

  test "Should store leaf blocks in local store":
    # Create overlay and store blocks with tree context
    let indices = toSeq(0 ..< blocks.len)
    (await localStore.storeBlocksWithOverlay(treeCid, blocks, tree)).tryGet()

    # Create pending handles for leaf addresses
    let pending =
      indices.mapIt(engine.pendingBlocks.getWantHandle(BlockAddress.init(treeCid, it)))

    # Create leaf deliveries with proofs
    let blocksDelivery = indices.mapIt(
      BlockDelivery(
        blk: blocks[it],
        address: BlockAddress.init(treeCid, it),
        proof: tree.getProof(it).tryGet().some,
      )
    )

    # Install NOP for want list cancellations so they don't cause a crash
    engine.network = BlockExcNetwork(
      request: BlockExcRequest(sendWantCancellations: NopSendWantCancellationsProc)
    )

    await engine.blocksDeliveryHandler(peerId, blocksDelivery, allowSpurious = true)
    let resolved = await allFinished(pending)
    check resolved.mapIt(it.read.blk) == blocks

    # Verify blocks are persisted with tree-aware hasBlock
    for i in indices:
      let present = await engine.localStore.hasBlock(treeCid, i)
      check present.tryGet()

  test "Should reject non-manifest non-leaf block deliveries":
    let pending = blocks.mapIt(engine.pendingBlocks.getWantHandle(it.cid))

    let blocksDelivery = blocks.mapIt(BlockDelivery(blk: it, address: it.address))

    # Install NOP for want list cancellations so they don't cause a crash
    engine.network = BlockExcNetwork(
      request: BlockExcRequest(sendWantCancellations: NopSendWantCancellationsProc)
    )

    await engine.blocksDeliveryHandler(peerId, blocksDelivery)

    for b in blocks:
      let present = await engine.localStore.hasBlock(b.cid)
      check not present.tryGet()

    for fut in pending:
      check not fut.finished
      await fut.cancelAndWait()

  test "Should handle block presence":
    proc sendWantList(
        id: PeerId,
        addresses: seq[BlockAddress],
        priority: int32 = 0,
        cancel: bool = false,
        wantType: WantType = WantType.WantHave,
        full: bool = false,
        sendDontHave: bool = false,
    ) {.async: (raises: [CancelledError]).} =
      engine.pendingBlocks.resolve(
        blocks.filterIt(it.address in addresses).mapIt(
          BlockDelivery(blk: it, address: it.address)
        )
      )

    engine.network =
      BlockExcNetwork(request: BlockExcRequest(sendWantList: sendWantList))

    # only Cids in peer want lists are requested
    for blk in blocks:
      discard engine.pendingBlocks.getWantHandle(blk.cid)

    await engine.blockPresenceHandler(
      peerId,
      blocks.mapIt(PresenceMessage.init(Presence(address: it.address, have: true))),
    )

    for a in blocks.mapIt(it.address):
      check a in peerCtx.peerHave

  test "Should send cancellations for received blocks":
    (await localStore.storeBlocksWithOverlay(treeCid, blocks, tree)).tryGet()

    let
      requestedIndices = @[0.Natural, 1.Natural]
      otherPeerId =
        PeerId.init(PrivateKey.random(rng[]).tryGet().getPublicKey().tryGet()).tryGet()
      pending = requestedIndices.mapIt(
        engine.pendingBlocks.getWantHandle(BlockAddress.init(treeCid, it))
      )
      blocksDelivery = requestedIndices.mapIt(
        BlockDelivery(
          blk: blocks[it],
          address: BlockAddress.init(treeCid, it),
          proof: tree.getProof(it).tryGet().some,
        )
      )
      cancellations =
        newTable(blocksDelivery.mapIt((it.address, newFuture[void]())).toSeq)

    proc sendWantCancellations(
        id: PeerId, addresses: seq[BlockAddress]
    ) {.async: (raises: [CancelledError]).} =
      check id == otherPeerId
      for address in addresses:
        cancellations[address].catch.expect("address should exist").complete()

    engine.network = BlockExcNetwork(
      request: BlockExcRequest(sendWantCancellations: sendWantCancellations)
    )

    let otherPeerCtx = BlockExcPeerCtx(id: otherPeerId)
    engine.peers.add(otherPeerCtx)

    for delivery in blocksDelivery:
      peerCtx.blocksRequested.incl(delivery.address)
      otherPeerCtx.blocksRequested.incl(delivery.address)

    await engine.blocksDeliveryHandler(peerId, blocksDelivery)
    discard await allFinished(pending).wait(1.seconds)
    await allFuturesThrowing(cancellations.values().toSeq)

asyncchecksuite "Block Download":
  var
    rng: Rng
    seckey: PrivateKey
    peerId: PeerId
    chunker: Chunker
    blockDiscovery: Discovery
    peerStore: PeerCtxStore
    pendingBlocks: PendingBlocksManager
    network: BlockExcNetwork
    engine: BlockExcEngine
    discovery: DiscoveryEngine
    advertiser: Advertiser
    peerCtx: BlockExcPeerCtx
    localStore: BlockStore
    blocks: seq[Block]
    tp: Taskpool

  setup:
    rng = Rng.instance()
    chunker = RandomChunker.new(rng, size = 1024'nb, chunkSize = 256'nb)

    while true:
      let chunk = (await chunker.getBytes()).tryGet()
      if chunk.len <= 0:
        break

      blocks.add(Block.new(chunk).tryGet())

    seckey = PrivateKey.random(rng[]).tryGet()
    peerId = PeerId.init(seckey.getPublicKey().tryGet()).tryGet()
    blockDiscovery = Discovery.new()
    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new()

    tp = Taskpool.new(num_threads = 4)
    localStore = RepoStore.new(
      SQLiteKVStore.new(SqliteMemory, tp).tryGet(),
      SQLiteKVStore.new(SqliteMemory, tp).tryGet(),
    )
    network = BlockExcNetwork()

    discovery = DiscoveryEngine.new(
      localStore,
      peerStore,
      network,
      blockDiscovery,
      pendingBlocks,
      concurrentDiscReqs = 0,
    )

    advertiser = Advertiser.new(localStore, blockDiscovery, concurrentAdvReqs = 0)

    engine = BlockExcEngine.new(
      localStore, network, discovery, advertiser, peerStore, pendingBlocks
    )

    peerCtx = BlockExcPeerCtx(id: peerId)
    engine.peers.add(peerCtx)
    await engine.start()

  teardown:
    await engine.stop()
    tp.shutdown()

  test "Should exhaust retries":
    var
      retries = 2
      address = BlockAddress.init(blocks[0].cid)

    proc sendWantList(
        id: PeerId,
        addresses: seq[BlockAddress],
        priority: int32 = 0,
        cancel: bool = false,
        wantType: WantType = WantType.WantHave,
        full: bool = false,
        sendDontHave: bool = false,
    ) {.async: (raises: [CancelledError]).} =
      check wantType == WantHave
      check not engine.pendingBlocks.isRequested(address)
      check engine.pendingBlocks.retries(address) == retries
      retries -= 1

    engine.pendingBlocks.blockRetries = 2
    engine.pendingBlocks.retryInterval = 10.millis
    engine.network =
      BlockExcNetwork(request: BlockExcRequest(sendWantList: sendWantList))

    let pending = engine.requestDelivery(address).tryGet()

    expect RetriesExhaustedEngineError:
      discard await pending

  test "Should request delivery handles":
    let address = BlockAddress.init(blocks[0].cid)

    let handles = (engine.requestDeliveries(@[address])).tryGet()
    check handles.len == 1

    engine.completeBlock(address, blocks[0])
    let delivery = await handles[0]
    check delivery.address == address
    check delivery.blk == blocks[0]

  test "Should deduplicate delivery requests":
    let address = BlockAddress.init(blocks[0].cid)

    let handles = (engine.requestDeliveries(@[address, address])).tryGet()

    check handles.len == 1
    check engine.pendingBlocks.wantListLen == 1

  test "Should resolve delivery handles independently":
    let
      address1 = BlockAddress.init(blocks[0].cid)
      address2 = BlockAddress.init(blocks[1].cid)
      handles = (engine.requestDeliveries(@[address1, address2])).tryGet()

    check handles.len == 2

    engine.completeBlock(address1, blocks[0])
    let delivery = await handles[0]

    check delivery.address == address1
    check delivery.blk == blocks[0]
    check not handles[1].finished

    engine.completeBlock(address2, blocks[1])
    let delivery2 = await handles[1]
    check delivery2.address == address2
    check delivery2.blk == blocks[1]

  test "Should isolate delivery handle failures":
    let
      address1 = BlockAddress.init(blocks[0].cid)
      address2 = BlockAddress.init(blocks[1].cid)
      handles = (engine.requestDeliveries(@[address1, address2])).tryGet()

    engine.pendingBlocks.failWantHandle(
      address1, QueueFailedEngineError, "Block request queue failed"
    )
    engine.completeBlock(address2, blocks[1])

    expect QueueFailedEngineError:
      discard await handles[0]

    let delivery = await handles[1]
    check delivery.address == address2
    check delivery.blk == blocks[1]

  test "Should batch want block requests to one peer":
    let
      addresses = blocks[0 .. 2].mapIt(BlockAddress.init(it.cid))
      done = newFuture[void]()

    var wantBlockBatches: seq[seq[BlockAddress]]

    proc sendWantList(
        id: PeerId,
        addresses: seq[BlockAddress],
        priority: int32 = 0,
        cancel: bool = false,
        wantType: WantType = WantType.WantHave,
        full: bool = false,
        sendDontHave: bool = false,
    ) {.async: (raises: [CancelledError]).} =
      if wantType == WantBlock:
        wantBlockBatches.add(addresses)
        done.complete()

    engine.network = BlockExcNetwork(
      request: BlockExcRequest(
        sendWantList: sendWantList, sendWantCancellations: NopSendWantCancellationsProc
      )
    )

    for address in addresses:
      peerCtx.setPresence(Presence(address: address, have: true))

    discard (engine.requestDeliveries(addresses)).tryGet()
    await done.wait(100.millis)

    check wantBlockBatches.len == 1
    check wantBlockBatches[0].mapIt($it).sorted(cmp[string]) ==
      addresses.mapIt($it).sorted(cmp[string])

  test "Should ignore stale timeout for newer same-peer request":
    let
      address = BlockAddress.init(blocks[0].cid)
      sent = newFuture[void]()

    proc sendWantList(
        id: PeerId,
        addresses: seq[BlockAddress],
        priority: int32 = 0,
        cancel: bool = false,
        wantType: WantType = WantType.WantHave,
        full: bool = false,
        sendDontHave: bool = false,
    ) {.async: (raises: [CancelledError]).} =
      if wantType == WantBlock:
        sent.complete()

    peerCtx.activityTimeout = 20.millis
    peerCtx.setPresence(Presence(address: address, have: true))
    engine.pendingBlocks.blockRetries = 3
    engine.network = BlockExcNetwork(
      request: BlockExcRequest(
        sendWantList: sendWantList, sendWantCancellations: NopSendWantCancellationsProc
      )
    )

    discard (engine.requestDeliveries(@[address])).tryGet()
    await sent.wait(100.millis)

    let retriesBefore = engine.pendingBlocks.retries(address)
    engine.pendingBlocks.clearRequest(address, peerId.some)
    peerCtx.blockRequestCancelled(address)
    let nextRequestId = engine.pendingBlocks.markRequested(address, peerId)
    check nextRequestId.isSome
    peerCtx.blockRequestScheduled(address)

    await sleepAsync(50.millis)

    check engine.pendingBlocks.isRequested(address)
    check engine.pendingBlocks.getRequestPeer(address) == peerId.some
    check engine.pendingBlocks.retries(address) == retriesBefore

  test "Should retry block request":
    var
      address = BlockAddress.init(blocks[0].cid)
      steps = newAsyncEvent()

    proc sendWantList(
        id: PeerId,
        addresses: seq[BlockAddress],
        priority: int32 = 0,
        cancel: bool = false,
        wantType: WantType = WantType.WantHave,
        full: bool = false,
        sendDontHave: bool = false,
    ) {.async: (raises: [CancelledError]).} =
      case wantType
      of WantHave:
        check engine.pendingBlocks.isRequested(address) == false
        check engine.pendingBlocks.retriesExhausted(address) == false
        steps.fire()
      of WantBlock:
        check engine.pendingBlocks.isRequested(address) == true
        check engine.pendingBlocks.retriesExhausted(address) == false
        steps.fire()

    engine.pendingBlocks.blockRetries = 10
    engine.pendingBlocks.retryInterval = 10.millis
    engine.network = BlockExcNetwork(
      request: BlockExcRequest(
        sendWantList: sendWantList, sendWantCancellations: NopSendWantCancellationsProc
      )
    )

    let pending = engine.requestDelivery(address).tryGet()
    await steps.wait()

    await engine.blockPresenceHandler(
      peerId, @[BlockPresence(address: address, `type`: BlockPresenceType.Have)]
    )

    await steps.wait()

    engine.completeBlock(address, blocks[0])
    check (await pending).blk == blocks[0]

  test "Should cancel block request":
    var
      address = BlockAddress.init(blocks[0].cid)
      done = newFuture[void]()

    proc sendWantList(
        id: PeerId,
        addresses: seq[BlockAddress],
        priority: int32 = 0,
        cancel: bool = false,
        wantType: WantType = WantType.WantHave,
        full: bool = false,
        sendDontHave: bool = false,
    ) {.async: (raises: [CancelledError]).} =
      done.complete()

    engine.pendingBlocks.blockRetries = 10
    engine.pendingBlocks.retryInterval = 1.seconds
    engine.network = BlockExcNetwork(
      request: BlockExcRequest(
        sendWantList: sendWantList, sendWantCancellations: NopSendWantCancellationsProc
      )
    )

    let pending = engine.requestDelivery(address).tryGet()
    await done.wait(100.millis)

    await pending.cancelAndWait()
    expect CancelledError:
      discard await pending

asyncchecksuite "Task Handler":
  var
    rng: Rng
    seckey: PrivateKey
    peerId: PeerId
    chunker: Chunker
    blockDiscovery: Discovery
    peerStore: PeerCtxStore
    pendingBlocks: PendingBlocksManager
    network: BlockExcNetwork
    engine: BlockExcEngine
    discovery: DiscoveryEngine
    advertiser: Advertiser
    localStore: RepoStore
    tp: Taskpool

    peersCtx: seq[BlockExcPeerCtx]
    peers: seq[PeerId]
    blocks: seq[Block]
    manifest: Manifest
    tree: ArchivistTree
    treeCid: Cid

  setup:
    rng = Rng.instance()
    chunker = RandomChunker.new(rng, size = 1024, chunkSize = 256'nb)
    while true:
      let chunk = (await chunker.getBytes()).tryGet()
      if chunk.len <= 0:
        break

      blocks.add(Block.new(chunk).tryGet())

    (manifest, tree) = makeManifestAndTree(blocks).tryGet()
    treeCid = tree.rootCid.tryGet()
    seckey = PrivateKey.random(rng[]).tryGet()
    peerId = PeerId.init(seckey.getPublicKey().tryGet()).tryGet()
    blockDiscovery = Discovery.new()
    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new()

    tp = Taskpool.new(num_threads = 4)
    localStore = RepoStore.new(
      SQLiteKVStore.new(SqliteMemory, tp).tryGet(),
      SQLiteKVStore.new(SqliteMemory, tp).tryGet(),
    )
    network = BlockExcNetwork()

    discovery =
      DiscoveryEngine.new(localStore, peerStore, network, blockDiscovery, pendingBlocks)

    advertiser = Advertiser.new(localStore, blockDiscovery)

    engine = BlockExcEngine.new(
      localStore, network, discovery, advertiser, peerStore, pendingBlocks
    )
    peersCtx = @[]

    for i in 0 .. 3:
      let seckey = PrivateKey.random(rng[]).tryGet()
      peers.add(PeerId.init(seckey.getPublicKey().tryGet()).tryGet())

      peersCtx.add(BlockExcPeerCtx(id: peers[i]))
      peerStore.add(peersCtx[i])

  teardown:
    tp.shutdown()

  test "Should send wanted blocks":
    proc sendBlocksDelivery(
        id: PeerId, blocksDelivery: seq[BlockDelivery]
    ) {.async: (raises: [CancelledError]).} =
      check blocksDelivery.len == 2
      check blocksDelivery.mapIt($it.address).sorted(cmp[string]) ==
        @[blocks[0].address, blocks[1].address].mapIt($it).sorted(cmp[string])

    # Store blocks with tree context
    (await localStore.storeBlocksWithOverlay(treeCid, blocks, tree)).tryGet()

    engine.network.request.sendBlocksDelivery = sendBlocksDelivery

    peersCtx[0].wantedBlocks.incl(blocks[0].address)
    peersCtx[0].wantedBlocks.incl(blocks[1].address)

    await engine.taskHandler(peersCtx[0])

  test "Should set in-flight for outgoing blocks":
    proc sendBlocksDelivery(
        id: PeerId, blocksDelivery: seq[BlockDelivery]
    ) {.async: (raises: [CancelledError]).} =
      check blocks[0].address in peersCtx[0].blocksSent

    # Store blocks with tree context
    (await localStore.storeBlocksWithOverlay(treeCid, blocks, tree)).tryGet()

    engine.network.request.sendBlocksDelivery = sendBlocksDelivery

    peersCtx[0].wantedBlocks.incl(blocks[0].address)
    await engine.taskHandler(peersCtx[0])

  test "Should clear in-flight when local lookup fails":
    peersCtx[0].wantedBlocks.incl(blocks[0].address)
    await engine.taskHandler(peersCtx[0])

    check blocks[0].address notin peersCtx[0].blocksSent
