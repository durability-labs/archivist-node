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
import pkg/archivist/blockexchange/engine/metrics
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
import ../../examples

privateAccess(PendingBlocksManager)
privateAccess(BlockReq)
privateAccess(BlockExcEngine)
privateAccess(BlockExcPeerCtx)

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

# Helper: a peer selector that always returns Requeue with a delay
proc alwaysRequeue(delay: Duration = 0.seconds): PeerSelectorHandler =
  proc selector(
      address: BlockAddress
  ): Future[?!PeerSelection] {.async: (raises: [CancelledError]), gcsafe.} =
    success PeerSelection(kind: PeerSelectionKind.Requeue, delay: delay)

  return selector

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
    await pendingBlocks.start()

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

    engine.pendingBlocks.getPeerForBlock = alwaysRequeue(30.seconds)

    for b in blocks:
      discard engine.pendingBlocks.getWantHandle(b.cid)

    await engine.setupPeer(peerId)

    await done.wait(100.millis)

  teardown:
    await pendingBlocks.stop()
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
    await pendingBlocks.start()

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
    pendingBlocks.getPeerForBlock = alwaysRequeue(30.seconds)

  teardown:
    await pendingBlocks.stop()
    tp.shutdown()

  test "Should schedule block requests":
    let wantList = makeWantList(blocks.mapIt(it.cid), wantType = WantType.WantBlock)
      # only `wantBlock` are stored in `wantedBlocks`

    when defined(metrics):
      let
        beforeLists = archivist_block_exchange_want_block_lists_received.value()
        beforeEntries = archivist_block_exchange_want_block_entries_received.value()

    proc handler() {.async.} =
      let ctx = await engine.taskQueue.pop()
      check ctx.id == peerId
      # only `wantBlock` scheduled
      check ctx.wantedBlocks.toSeq.mapIt($it.cidOrTreeCid).sorted ==
        blocks.mapIt($it.cid).sorted

    let done = handler()
    await engine.wantListHandler(peerId, wantList)
    await done

    when defined(metrics):
      check archivist_block_exchange_want_block_lists_received.value() == beforeLists + 1
      check archivist_block_exchange_want_block_entries_received.value() ==
        beforeEntries + blocks.len.float64

  test "Should handle want list":
    let wantList = makeWantList(blocks.mapIt(it.cid))
    var
      done = newFuture[void]()
      received: seq[BlockPresence]

    when defined(metrics):
      let
        beforeLists = archivist_block_exchange_want_have_lists_received.value()
        beforeEntries = archivist_block_exchange_want_have_entries_received.value()

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

    when defined(metrics):
      check archivist_block_exchange_want_have_lists_received.value() == beforeLists + 1
      check archivist_block_exchange_want_have_entries_received.value() ==
        beforeEntries + blocks.len.float64

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

    await engine.blocksDeliveryHandler(peerId, blocksDelivery)
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
        if fut =? cancellations.getOrDefault(address).option and not fut.finished:
          fut.complete()

    engine.network = BlockExcNetwork(
      request: BlockExcRequest(sendWantCancellations: sendWantCancellations)
    )

    let otherPeerCtx = BlockExcPeerCtx.new(otherPeerId)
    engine.peers.add(otherPeerCtx)

    # Request blocks AFTER network and peers are set up
    let pending = requestedIndices.mapIt(
      engine.pendingBlocks.getWantHandle(BlockAddress.init(treeCid, it))
    )

    for delivery in blocksDelivery:
      engine.pendingBlocks.markRequested(delivery.address, peerCtx)
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

  test "Should batch by peer before splitting want block requests":
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
      expectedPeer1 = initHashSet[BlockAddress]()
      expectedPeer2 = initHashSet[BlockAddress]()
      wantBlockBatches: seq[tuple[peer: PeerId, addresses: seq[BlockAddress]]]

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
        wantBlockBatches.add((peer: id, addresses: requestedAddresses))
        for address in requestedAddresses:
          sentAddresses.incl(address)
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
        expectedPeer1.incl(address)
        peerCtx.setPresence(Presence(address: address, have: true))
      else:
        expectedPeer2.incl(address)
        peer2Ctx.setPresence(Presence(address: address, have: true))

    let pendingHandles = engine.requestDeliveries(addresses).tryGet()
    check pendingHandles.len == requestCount
    await done.wait().wait(1.seconds)

    let
      peer1Batches = wantBlockBatches.filterIt(it.peer == peerId)
      peer2Batches = wantBlockBatches.filterIt(it.peer == peer2Id)

    var
      peer1Sent = initHashSet[BlockAddress]()
      peer2Sent = initHashSet[BlockAddress]()

    for batch in peer1Batches:
      for address in batch.addresses:
        peer1Sent.incl(address)

    for batch in peer2Batches:
      for address in batch.addresses:
        peer2Sent.incl(address)

    check:
      pendingHandles.len == requestCount
      sentAddresses == addresses.toHashSet
      peer1Batches.len == 2
      peer2Batches.len == 2
      peer1Batches.allIt(it.addresses.len == DefaultWantBlockBatchSize)
      peer2Batches.allIt(it.addresses.len == DefaultWantBlockBatchSize)
      peer1Sent == expectedPeer1
      peer2Sent == expectedPeer2
      sentAddresses.len == requestCount

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
      sent = newAsyncEvent()

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
        if not sent.isSet:
          sent.fire()

    peerCtx.setPresence(Presence(address: address, have: true))
    engine.pendingBlocks.retries = 3
    engine.network = BlockExcNetwork(
      request: BlockExcRequest(
        sendWantList: sendWantList, sendWantCancellations: NopSendWantCancellationsProc
      )
    )

    discard (engine.requestDeliveries(@[address])).tryGet()
    await sent.wait().wait(100.millis)
    await sleepAsync(50.millis) # let markRequested run post-send

    let retriesBefore = engine.pendingBlocks.retries(address)
    # markRequested already ran in peerBatchWorker post-send
    check engine.pendingBlocks.isRequested(address)
    check engine.pendingBlocks.getRequestPeer(address) == peerId.some
    check engine.pendingBlocks.retries(address) == retriesBefore

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
        sent.complete()

    engine.network = BlockExcNetwork(
      request: BlockExcRequest(
        sendWantList: sendWantList, sendWantCancellations: NopSendWantCancellationsProc
      )
    )
    peerCtx.setPresence(Presence(address: address, have: true))

    let pending = engine.requestDelivery(address).tryGet()
    let retriesBefore = engine.pendingBlocks.retries(address)

    await sent.wait(100.millis)

    # Wait for the WantBlock send (event-driven, not timeout-based)
    await sent.wait(1.seconds)
    check engine.pendingBlocks.isRequested(address)
    # markRequested decrements retries internally now
    check engine.pendingBlocks.retries(address) == retriesBefore - 1

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
    let retriesBefore = engine.pendingBlocks.retries(address)

    await wantHaveSent.wait().wait(100.millis)
    # Only WantHave sent so far -- markRequested not called yet
    check engine.pendingBlocks.retries(address) == retriesBefore
    check address in engine.pendingBlocks
    await engine.blockPresenceHandler(
      peerId, @[BlockPresence(address: address, `type`: BlockPresenceType.Have)]
    )
    check address in engine.pendingBlocks

    # Wait for WantBlock (event-driven)
    await wantBlockSent.wait().wait(1.seconds)
    check address in engine.pendingBlocks
    check engine.pendingBlocks.isRequested(address)
    # markRequested decrements retries internally now
    check engine.pendingBlocks.retries(address) == retriesBefore - 1
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

    check eventually address notin peerCtx.blocksRequested

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
    await sleepAsync(50.millis) # let markRequested run post-send
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
    await sleepAsync(50.millis) # let monitor defer clear peer assignment
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
    await sleepAsync(50.millis) # let markRequested run post-send
    check address in peerCtx.blocksRequested

    await engine.completeBlock(address, blocks[0])
    await sleepAsync(50.millis) # let monitor defer clear peer assignment
    check address notin peerCtx.blocksRequested
    check (await pending).blk == blocks[0]

  test "Peers exist locally flows through to sendBatch":
    let
      address = BlockAddress.init(blocks[0].cid)
      wantBlockSent = newAsyncEvent()

    # Pre-populate peerHave so the selector finds the peer locally.
    peerCtx.setPresence(Presence(address: address, have: true))

    proc sendWantList(
        id: PeerId,
        addresses: seq[BlockAddress],
        priority: int32 = 0,
        cancel: bool = false,
        wantType: WantType = WantType.WantHave,
        full: bool = false,
        sendDontHave: bool = false,
    ) {.async: (raises: [CancelledError]).} =
      if wantType == WantType.WantBlock:
        check addresses == @[address]
        if not wantBlockSent.isSet:
          wantBlockSent.fire()

    engine.network = BlockExcNetwork(
      request: BlockExcRequest(
        sendWantList: sendWantList, sendWantCancellations: NopSendWantCancellationsProc
      )
    )

    let pending = engine.requestDelivery(address).tryGet()

    # Block flows through: selector finds peer locally -> pipe -> worker -> sendBatch.
    # No requeue, no discoverer - the peer is known to have the block.
    await wantBlockSent.wait().wait(1.seconds)
    check address in engine.pendingBlocks
    check engine.pendingBlocks.isRequested(address)
    check address in peerCtx.blocksRequested
    await pending.cancelAndWait()
    expect CancelledError:
      discard await pending

  test "Peer knowledge refresh reschedules with discoveryTimeout":
    let
      address = BlockAddress.init(blocks[0].cid)
      wantHaveSent = newAsyncEvent()
      wantBlockSent = newAsyncEvent()

    # peerCtx is in engine.peers (from setup) but peerHave is empty.
    # getPeerForBlock sends WantHave to refresh knowledge, then returns Requeue.
    # The test simulates the peer's response via blockPresenceHandler.

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
      of WantType.WantHave:
        check addresses == @[address]
        if not wantHaveSent.isSet:
          wantHaveSent.fire()
      of WantType.WantBlock:
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

    # Wait for WantHave (sent by getPeerForBlock's refresh pass).
    await wantHaveSent.wait().wait(1.seconds)
    # At this point: getPeerForBlock returned Requeue after refresh, so
    # blockDispatchMonitor requeued the block. blockPresenceHandler will later
    # wakeAddress -> WantBlock.
    check address in engine.pendingBlocks
    check not engine.pendingBlocks.isRequested(address)

    # Simulate the peer's response to the refresh's WantHave.
    await engine.blockPresenceHandler(
      peerId, @[BlockPresence(address: address, `type`: BlockPresenceType.Have)]
    )

    # Now the block flows through: blockPresenceHandler updates peerHave
    # and calls wakeAddress -> selector returns peer -> sendBatch.
    check address in engine.pendingBlocks
    await wantBlockSent.wait().wait(1.seconds)
    check eventually engine.pendingBlocks.isRequested(address)
    check address in peerCtx.blocksRequested
    await pending.cancelAndWait()
    expect CancelledError:
      discard await pending

  test "DHT discovery reschedules with discoveryTimeout":
    let
      address = BlockAddress.init(blocks[0].cid)
      newPeerId =
        PeerId.init(PrivateKey.random(rng[]).tryGet().getPublicKey().tryGet()).tryGet()
      newPeerCtx = BlockExcPeerCtx.new(newPeerId)
      wantBlockSent = newAsyncEvent()
      initialLastDiscRequest = engine.lastDiscRequest

    # No peer has the block. getPeerForBlock refreshes existing peers (none
    # have it) and falls back to searchForNewPeers (DHT). The test simulates
    # DHT finding a new peer by adding it and calling blockPresenceHandler.

    proc sendWantList(
        id: PeerId,
        addresses: seq[BlockAddress],
        priority: int32 = 0,
        cancel: bool = false,
        wantType: WantType = WantType.WantHave,
        full: bool = false,
        sendDontHave: bool = false,
    ) {.async: (raises: [CancelledError]).} =
      if wantType == WantType.WantBlock:
        check addresses == @[address]
        if not wantBlockSent.isSet:
          wantBlockSent.fire()

    engine.network = BlockExcNetwork(
      request: BlockExcRequest(
        sendWantList: sendWantList, sendWantCancellations: NopSendWantCancellationsProc
      )
    )

    # Remove the existing peerCtx so no peer is known to have the block.
    # The discoverer's refreshBlockKnowledge will find nothing.
    engine.peers.remove(peerCtx.id)

    let pending = engine.requestDelivery(address).tryGet()

    # Wait for searchForNewPeers to fire (lastDiscRequest advances).
    # The discoverer runs: refreshBlockKnowledge finds nothing (no peers),
    # then searchForNewPeers is called.
    var discoveryRequestFired = false
    for _ in 0 ..< 200:
      if engine.lastDiscRequest > initialLastDiscRequest:
        discoveryRequestFired = true
        break
      await sleepAsync(5.millis)
    check discoveryRequestFired

    # Simulate DHT discovery: a new peer connects and announces it has the block.
    engine.peers.add(newPeerCtx)
    await engine.blockPresenceHandler(
      newPeerId, @[BlockPresence(address: address, `type`: BlockPresenceType.Have)]
    )

    # Block flows through: blockPresenceHandler updates newPeerCtx.peerHave
    # and calls wakeAddress -> selector returns newPeerCtx -> sendBatch.
    await wantBlockSent.wait().wait(1.seconds)
    check address in engine.pendingBlocks
    check eventually engine.pendingBlocks.isRequested(address)
    check address in newPeerCtx.blocksRequested
    await pending.cancelAndWait()
    expect CancelledError:
      discard await pending

  test "Positive presence wakes scored peer":
    let
      address = BlockAddress.init(blocks[0].cid)
      announcerPeer = peerCtx
      scorerKey = PrivateKey.random(rng[]).tryGet()
      scorerId = PeerId.init(scorerKey.getPublicKey().tryGet()).tryGet()
      scorerPeer = BlockExcPeerCtx.new(scorerId)
      wantBlockSent = newAsyncEvent()

    var wantBlockPeer: PeerId
    var firstWantBlock = true
    proc sendWantList(
        id: PeerId,
        addresses: seq[BlockAddress],
        priority: int32 = 0,
        cancel: bool = false,
        wantType: WantType = WantType.WantHave,
        full: bool = false,
        sendDontHave: bool = false,
    ) {.async: (raises: [CancelledError]).} =
      if wantType == WantType.WantBlock:
        check addresses == @[address]
        if firstWantBlock:
          wantBlockPeer = id
          firstWantBlock = false
        check wantBlockPeer == id
        if not wantBlockSent.isSet:
          wantBlockSent.fire()

    engine.network = BlockExcNetwork(
      request: BlockExcRequest(
        sendWantList: sendWantList, sendWantCancellations: NopSendWantCancellationsProc
      )
    )

    # Both peers exist in the store.
    engine.peers.add(scorerPeer)

    # Inject a scorer that always picks the scorerPeer when both are eligible.
    engine.selectPeer = proc(
        peers: seq[BlockExcPeerCtx], address: BlockAddress
    ): BlockExcPeerCtx {.gcsafe, raises: [].} =
      for p in peers:
        if p.id == scorerId:
          return p
      peers[0]

    let pending = engine.requestDelivery(address).tryGet()

    # Wait for first selection to requeue (neither peer has presence yet).
    # Then both peers report Have for the address.
    await sleepAsync(100.millis) # let first selector call happen

    # Both peers report presence. blockPresenceHandler for the announcer
    # wakes the monitor, which re-enters selection and the scorer picks scorerPeer.
    await engine.blockPresenceHandler(
      announcerPeer.id,
      @[BlockPresence(address: address, `type`: BlockPresenceType.Have)],
    )
    await engine.blockPresenceHandler(
      scorerId, @[BlockPresence(address: address, `type`: BlockPresenceType.Have)]
    )

    # Exactly one WantBlock sent — to the scorer-selected peer, not the announcer.
    await wantBlockSent.wait().wait(2.seconds)
    check wantBlockPeer == scorerId
    check eventually engine.pendingBlocks.isRequested(address)
    check address in scorerPeer.blocksRequested
    check address notin announcerPeer.blocksRequested

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

suite "NetworkStore engine refresh circuit":
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
    tree: ArchivistTree
    treeCid: Cid
    tp: Taskpool
    sentFull: bool
    sentAddresses: seq[BlockAddress]

  proc capturingSendWantList(
      id: PeerId,
      addresses: seq[BlockAddress],
      priority: int32 = 0,
      cancel: bool = false,
      wantType: WantType = WantType.WantHave,
      full: bool = false,
      sendDontHave: bool = false,
  ) {.async: (raises: [CancelledError]).} =
    sentFull = full
    sentAddresses = addresses

  setup:
    rng = Rng.instance()
    chunker = RandomChunker.new(rng, size = 1024'nb, chunkSize = 256'nb)
    blocks = @[]
    while true:
      let chunk = (await chunker.getBytes()).tryGet()
      if chunk.len <= 0:
        break
      blocks.add(Block.new(chunk).tryGet())

    (_, tree) = makeManifestAndTree(blocks).tryGet()
    treeCid = tree.rootCid.tryGet()
    seckey = PrivateKey.random(rng[]).tryGet()
    peerId = PeerId.init(seckey.getPublicKey().tryGet()).tryGet()
    blockDiscovery = Discovery.new()
    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new()
    waitFor pendingBlocks.start()
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
    pendingBlocks.getPeerForBlock = alwaysRequeue(30.seconds)
    network.request.sendWantList = capturingSendWantList
    sentFull = false
    sentAddresses = @[]
    for b in blocks:
      discard engine.pendingBlocks.getWantHandle(b.cid)

  teardown:
    waitFor pendingBlocks.stop()
    tp.shutdown()

  test "suppressed refresh returns wake hint":
    let baseTime = Moment.now()
    peerCtx.state = WantListState.Wait
    peerCtx.windowOpenTime = baseTime
    peerCtx.lastSendTime = baseTime
    sentAddresses = @[]
    sentFull = true
    let wake = await engine.refreshBlockKnowledge(peerCtx)
    let afterCall = Moment.now()
    check sentAddresses.len == 0
    check wake.isSome
    check wake.unsafeGet() <= peerCtx.lastSendTime + peerCtx.deltaInterval - baseTime
    check wake.unsafeGet() >= peerCtx.lastSendTime + peerCtx.deltaInterval - afterCall

  test "full-resend from closed state sends full=true with all addresses":
    check peerCtx.state == WantListState.Closed
    discard await engine.refreshBlockKnowledge(peerCtx)
    check sentFull == true
    check sentAddresses.len == blocks.len

  test "delta-send within active window sends only new blocks with full=false":
    peerCtx.state = WantListState.SendDelta
    peerCtx.windowOpenTime = Moment.now()
    peerCtx.alreadySent = initHashSet[BlockAddress]()
    peerCtx.alreadySent.incl(blocks[0].address)
    sentAddresses = @[]
    sentFull = true
    discard await engine.refreshBlockKnowledge(peerCtx)
    check sentFull == false
    check sentAddresses.len == blocks.len - 1
    check blocks[0].address notin sentAddresses

  test "suppression when delta is empty sends nothing":
    peerCtx.state = WantListState.SendDelta
    peerCtx.windowOpenTime = Moment.now()
    for b in blocks:
      peerCtx.alreadySent.incl(b.address)
    sentAddresses = @[]
    sentFull = true
    discard await engine.refreshBlockKnowledge(peerCtx)
    check sentAddresses.len == 0

  test "wait state with delta interval not elapsed sends nothing":
    peerCtx.state = WantListState.Wait
    peerCtx.windowOpenTime = Moment.now()
    peerCtx.lastSendTime = Moment.now()
    sentAddresses = @[]
    sentFull = true
    discard await engine.refreshBlockKnowledge(peerCtx)
    check sentAddresses.len == 0

  test "window expiry in wait state triggers full resend":
    peerCtx.state = WantListState.Wait
    peerCtx.windowOpenTime = Moment.now() - 11.seconds
    peerCtx.lastSendTime = Moment.now() - 11.seconds
    peerCtx.alreadySent = initHashSet[BlockAddress]()
    peerCtx.alreadySent.incl(blocks[0].address)
    sentAddresses = @[]
    sentFull = false
    discard await engine.refreshBlockKnowledge(peerCtx)
    check sentFull == true
    check sentAddresses.len == blocks.len
    check peerCtx.alreadySent.len == blocks.len

  test "peerHave filtering excludes blocks peer has":
    peerCtx.state = WantListState.Closed
    let pres = Presence(address: blocks[0].address, have: true)
    peerCtx.setPresence(pres)
    sentAddresses = @[]
    sentFull = false
    discard await engine.refreshBlockKnowledge(peerCtx)
    check blocks[0].address notin sentAddresses
    check sentAddresses.len == blocks.len - 1
