import std/sequtils
import std/algorithm
import std/sets
import std/importutils

import pkg/chronos
import pkg/libp2p/routing_record
import pkg/stew/bitseqs
import pkg/archivistdht/discv5/protocol as discv5

import pkg/kvstore
import pkg/taskpools

import pkg/archivist/rng
import pkg/archivist/blockexchange
import pkg/archivist/blockexchange/engine/engine {.all.}
import pkg/archivist/blockexchange/engine/pendingblocks {.all.}
import pkg/archivist/stores
import pkg/archivist/chunker
import pkg/archivist/discovery
import pkg/archivist/blocktype
import pkg/archivist/manifest
import pkg/archivist/merkletree
import pkg/archivist/utils/asyncheapqueue
import ../../../asynctest
import ../../helpers

privateAccess(PendingBlocksManager)
privateAccess(BlockReq)

const NopSendWantListProc = proc(
    id: PeerId,
    addresses: seq[BlockAddress],
    priority: int32 = 0,
    cancel: bool = false,
    wantType: WantType = WantType.WantHave,
    full: bool = false,
    sendDontHave: bool = false,
) {.async: (raises: [CancelledError]).} =
  discard

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

    peerCtx = BlockExcPeerCtx.new(peerId)
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
      await engine.pendingBlocks.resolve(
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

    let otherPeerCtx = BlockExcPeerCtx.new(otherPeerId)
    engine.peers.add(otherPeerCtx)

    for delivery in blocksDelivery:
      engine.pendingBlocks.blocks[delivery.address].state = Scheduled
      engine.pendingBlocks.markRequested(delivery.address, peerCtx, 60.seconds)
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
    network = BlockExcNetwork(
      request: BlockExcRequest(
        sendWantList: NopSendWantListProc,
        sendWantCancellations: NopSendWantCancellationsProc,
      )
    )

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

    peerCtx = BlockExcPeerCtx.new(peerId)
    engine.peers.add(peerCtx)
    await engine.start()

  teardown:
    await engine.stop()
    tp.shutdown()

  test "Should fail exhausted requests before queueing":
    let address = BlockAddress.init(blocks[0].cid)

    engine.pendingBlocks.retries = 0

    let pending = engine.requestDelivery(address).tryGet()

    check address in engine.pendingBlocks
    expect RetriesExhaustedEngineError:
      discard await pending

  test "Should request delivery handles":
    let address = BlockAddress.init(blocks[0].cid)

    let handles = (engine.requestDeliveries(@[address])).tryGet()
    check handles.len == 1

    await engine.completeBlock(address, blocks[0])
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

    await engine.completeBlock(address1, blocks[0])
    let delivery = await handles[0]

    check delivery.address == address1
    check delivery.blk == blocks[0]
    check not handles[1].finished

    await engine.completeBlock(address2, blocks[1])
    let delivery2 = await handles[1]
    check delivery2.address == address2
    check delivery2.blk == blocks[1]

  test "Should isolate delivery handle failures":
    let
      address1 = BlockAddress.init(blocks[0].cid)
      address2 = BlockAddress.init(blocks[1].cid)
      handles = (engine.requestDeliveries(@[address1, address2])).tryGet()

    await engine.pendingBlocks.failWantHandle(
      address1, QueueFailedEngineError, "Block request queue failed"
    )
    await engine.completeBlock(address2, blocks[1])

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

  test "Should keep request queued while timed-out batch is sending":
    let
      firstAddress = BlockAddress.init(blocks[0].cid)
      secondAddress = BlockAddress.init(blocks[1].cid)
      secondSent = newAsyncEvent()

    var queuedSecond = false
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

        if firstAddress in addresses and not queuedSecond:
          queuedSecond = true
          let secondRequest = engine.requestDelivery(secondAddress)
          check secondRequest.isOk

        if secondAddress in addresses:
          secondSent.fire()

    engine.network = BlockExcNetwork(
      request: BlockExcRequest(
        sendWantList: sendWantList, sendWantCancellations: NopSendWantCancellationsProc
      )
    )
    peerCtx.setPresence(Presence(address: firstAddress, have: true))
    peerCtx.setPresence(Presence(address: secondAddress, have: true))

    discard engine.requestDelivery(firstAddress).tryGet()

    await secondSent.wait().wait(250.millis)

    check wantBlockBatches == @[@[firstAddress], @[secondAddress]]

  test "Send all blocks to all peers":
    let
      peer2Key = PrivateKey.random(rng[]).tryGet()
      peer2Id = PeerId.init(peer2Key.getPublicKey().tryGet()).tryGet()
      peer2Ctx = BlockExcPeerCtx.new(peer2Id)
      requestCount = DefaultWantBlockBatchSize * 4
      addresses =
        toSeq(0 ..< requestCount).mapIt(BlockAddress.init(blocks[0].cid, Natural(it)))
      done = newAsyncEvent()

    var
      sentAddresses = initHashSet[BlockAddress]()
      wantBlockBatches: Table[PeerId, seq[BlockAddress]]

    proc sendWantList(
        id: PeerId,
        requestedAddresses: seq[BlockAddress],
        priority: int32 = 0,
        cancel: bool = false,
        wantType: WantType = WantType.WantHave,
        full: bool = false,
        sendDontHave: bool = false,
    ) {.async: (raises: [CancelledError]).} =
      if wantType == WantBlock:
        wantBlockBatches.mgetOrPut(id, @[]).add(requestedAddresses)
        sentAddresses.incl(requestedAddresses.toHashSet)

        if sentAddresses.len == requestCount and not done.isSet:
          done.fire()

    engine.peers.add(peer2Ctx)
    engine.network = BlockExcNetwork(
      request: BlockExcRequest(
        sendWantList: sendWantList, sendWantCancellations: NopSendWantCancellationsProc
      )
    )

    for i, address in addresses:
      if i mod 2 == 0:
        peerCtx.setPresence(Presence(address: address, have: true))
      else:
        peer2Ctx.setPresence(Presence(address: address, have: true))

    let pendingHandles = engine.requestDeliveries(addresses).tryGet()
    check pendingHandles.len == requestCount
    await done.wait().wait(1.seconds)

    check:
      sentAddresses == addresses.toHashSet
      wantBlockBatches[peerCtx.id].len == requestCount div 2
      wantBlockBatches[peer2Ctx.id].len == requestCount div 2

  test "Should dispatch timed-out batch for correct peer":
    let
      firstAddress = BlockAddress.init(blocks[0].cid)
      secondAddress = BlockAddress.init(blocks[2].cid)
      done = newAsyncEvent()

    var dispatchedBatches: seq[tuple[peer: PeerId, addresses: seq[BlockAddress]]]

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
        dispatchedBatches.add((peer: id, addresses: addresses))
        if not done.isSet:
          done.fire()

    engine.network = BlockExcNetwork(
      request: BlockExcRequest(
        sendWantList: sendWantList, sendWantCancellations: NopSendWantCancellationsProc
      )
    )
    peerCtx.setPresence(Presence(address: firstAddress, have: true))
    peerCtx.setPresence(Presence(address: secondAddress, have: true))

    check:
      engine.requestDelivery(firstAddress).isOk
      engine.requestDelivery(secondAddress).isOk

    await done.wait().wait(100.millis)

    check:
      dispatchedBatches.len == 1
      dispatchedBatches[0].peer == peerId
      dispatchedBatches[0].addresses.len == 2
      firstAddress in dispatchedBatches[0].addresses
      secondAddress in dispatchedBatches[0].addresses

    await engine.completeBlock(firstAddress, blocks[0])
    await engine.completeBlock(secondAddress, blocks[2])

  test "Should keep same peer request after clearing previous request":
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
    engine.pendingBlocks.retries = 3
    engine.network = BlockExcNetwork(
      request: BlockExcRequest(
        sendWantList: sendWantList, sendWantCancellations: NopSendWantCancellationsProc
      )
    )

    discard (engine.requestDeliveries(@[address])).tryGet()
    await sent.wait(100.millis)

    let retriesBefore = engine.pendingBlocks.retries(address)
    await engine.pendingBlocks.clearRequest(address, peerCtx)
    engine.pendingBlocks.blocks[address].state = Scheduled
    engine.pendingBlocks.markRequested(address, peerCtx)
    check engine.pendingBlocks.isRequested(address)
    check engine.pendingBlocks.getRequestPeer(address) == peerId.some
    # markRequested decrements retries internally now
    check engine.pendingBlocks.retries(address) == retriesBefore - 1

  test "Should gate queued sends and decrement on send":
    let address = BlockAddress.init(blocks[0].cid)
    let sent = newFuture[void]()

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
        check addresses == @[address]
        check engine.pendingBlocks.isRequested(address)
        sent.complete()

    engine.network = BlockExcNetwork(
      request: BlockExcRequest(
        sendWantList: sendWantList, sendWantCancellations: NopSendWantCancellationsProc
      )
    )
    peerCtx.setPresence(Presence(address: address, have: true))

    let pending = engine.requestDelivery(address).tryGet()

    # Wait for the WantBlock send (event-driven, not timeout-based)
    await sent.wait(1.seconds)
    check engine.pendingBlocks.isRequested(address)
    check address in peerCtx.blocksRequested
    let actualRetries = engine.pendingBlocks.retries(address)
    check actualRetries == DefaultBlockRetries - 1

    # retryAddresses requeues the block but does not decrement retries itself
    await engine.pendingBlocks.retryAddresses(@[address], DefaultBlockSendRetryDelay)
    check address in engine.pendingBlocks
    # Retries unchanged - retryAddresses does not call markRequested
    check engine.pendingBlocks.retries(address) == DefaultBlockRetries - 1

    await engine.completeBlock(address, blocks[0])
    check (await pending).blk == blocks[0]

  test "Should schedule retry when no peer has the block":
    let
      address = BlockAddress.init(blocks[0].cid)
      wantHaveSent = newAsyncEvent()
      wantBlockSent = newAsyncEvent()

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
        check addresses == @[address]
        if not wantHaveSent.isSet:
          wantHaveSent.fire()
      of WantBlock:
        check addresses == @[address]
        check wantHaveSent.isSet
        check address in peerCtx.peerHave
        if not wantBlockSent.isSet:
          wantBlockSent.fire()

    engine.network = BlockExcNetwork(
      request: BlockExcRequest(
        sendWantList: sendWantList, sendWantCancellations: NopSendWantCancellationsProc
      )
    )

    let pending = engine.requestDelivery(address).tryGet()

    # Wait for WantHave (event-driven)
    await wantHaveSent.wait().wait(1.seconds)
    # Only WantHave sent so far - markRequested not called yet
    check engine.pendingBlocks.retries(address) == DefaultBlockRetries
    check address in engine.pendingBlocks

    await engine.blockPresenceHandler(
      peerId, @[BlockPresence(address: address, `type`: BlockPresenceType.Have)]
    )
    check address in engine.pendingBlocks

    # Wait for WantBlock (event-driven)
    await wantBlockSent.wait().wait(1.seconds)
    check address in engine.pendingBlocks
    check engine.pendingBlocks.isRequested(address)
    check address in peerCtx.blocksRequested
    check engine.pendingBlocks.retries(address) == DefaultBlockRetries - 1
    await pending.cancelAndWait()
    expect CancelledError:
      discard await pending

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

    engine.pendingBlocks.retries = 10
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

    await engine.completeBlock(address, blocks[0])
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

    engine.pendingBlocks.retries = 10
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

  test "Should clear peer request state when delivery handle is cancelled":
    let
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
      if wantType == WantBlock:
        check addresses == @[address]
        done.complete()

    engine.pendingBlocks.retries = 10
    engine.network = BlockExcNetwork(
      request: BlockExcRequest(
        sendWantList: sendWantList, sendWantCancellations: NopSendWantCancellationsProc
      )
    )
    peerCtx.setPresence(Presence(address: address, have: true))

    let pending = engine.requestDelivery(address).tryGet()
    await done.wait(100.millis)
    check address in peerCtx.blocksRequested

    await pending.cancelAndWait()
    expect CancelledError:
      discard await pending

    check address notin peerCtx.blocksRequested

  test "Should clear peer request state when completing requested blocks":
    let
      addresses = blocks[0 .. 1].mapIt(BlockAddress.init(it.cid))
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
      if wantType == WantBlock:
        done.complete()

    engine.pendingBlocks.retries = 10
    engine.network = BlockExcNetwork(
      request: BlockExcRequest(
        sendWantList: sendWantList, sendWantCancellations: NopSendWantCancellationsProc
      )
    )

    for address in addresses:
      peerCtx.setPresence(Presence(address: address, have: true))

    let pending = engine.requestDeliveries(addresses).tryGet()
    await done.wait(100.millis)
    for address in addresses:
      check address in peerCtx.blocksRequested

    await engine.completeBlocks(
      @[
        BlockDelivery(address: addresses[0], blk: blocks[0]),
        BlockDelivery(address: addresses[1], blk: blocks[1]),
      ]
    )

    for handle in pending:
      discard await handle
    for address in addresses:
      check address notin peerCtx.blocksRequested

  test "Should clear peer request state when completion cancellation send fails":
    let
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
      if wantType == WantBlock:
        done.complete()

    proc sendWantCancellations(
        id: PeerId, addresses: seq[BlockAddress]
    ) {.async: (raises: [CancelledError]).} =
      raise newException(CancelledError, "cancelled cancellation send")

    engine.pendingBlocks.retries = 10
    engine.network = BlockExcNetwork(
      request: BlockExcRequest(
        sendWantList: sendWantList, sendWantCancellations: sendWantCancellations
      )
    )
    peerCtx.setPresence(Presence(address: address, have: true))

    let pending = engine.requestDelivery(address).tryGet()
    await done.wait(100.millis)
    check address in peerCtx.blocksRequested

    await engine.completeBlock(address, blocks[0])

    check address notin peerCtx.blocksRequested
    check (await pending).blk == blocks[0]

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

      peersCtx.add(BlockExcPeerCtx.new(peers[i]))
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
