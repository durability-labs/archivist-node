import std/sequtils
import std/algorithm
import std/importutils

import pkg/chronos
import pkg/libp2p
import pkg/stew/byteutils
import pkg/questionable

import pkg/archivist/rng
import pkg/archivist/blocktype as bt
import pkg/archivist/blockexchange {.all.}
import pkg/archivist/blockexchange/engine/pendingblocks {.all.}
import pkg/archivist/blockexchange/engine/errors {.all.}
import pkg/archivist/utils/trackedfutures

import ../helpers
import ../../asynctest

privateAccess(PendingBlocksManager)
privateAccess(BatchReq)
privateAccess(BlockReq)

proc makePeerId(): PeerId =
  let seckey = PrivateKey.random(Rng.instance()[]).tryGet()
  PeerId.init(seckey.getPublicKey().tryGet()).tryGet()

proc makePeerCtx(id: PeerId): BlockExcPeerCtx =
  BlockExcPeerCtx.new(id)

# Helper: a no-op sendBatch that just succeeds
proc nopSendBatch(
    peer: BlockExcPeerCtx, batch: seq[BlockAddress]
): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
  success()

# Helper: a peer selector that always returns the given peer
proc alwaysPeer(peerCtx: BlockExcPeerCtx): PeerSelectorHandler =
  proc selector(
      address: BlockAddress
  ): Future[?!PeerSelection] {.async: (raises: [CancelledError]), gcsafe.} =
    success PeerSelection(kind: PeerSelectionKind.Peer, peer: peerCtx)

  return selector

# Helper: a peer selector that always returns Requeue with a delay
proc alwaysRequeue(delay: Duration = 0.seconds): PeerSelectorHandler =
  proc selector(
      address: BlockAddress
  ): Future[?!PeerSelection] {.async: (raises: [CancelledError]), gcsafe.} =
    success PeerSelection(kind: PeerSelectionKind.Requeue, delay: delay)

  return selector

proc startWithoutDispatch(pb: PendingBlocksManager): Future[void] {.async.} =
  pb.getPeerForBlock = alwaysRequeue(30.seconds)
  await pb.start()

suite "Pending Blocks":
  test "Should add want handle":
    let
      pendingBlocks = PendingBlocksManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet

    await startWithoutDispatch(pendingBlocks)
    discard pendingBlocks.getWantHandle(blk.cid)

    check blk.cid in pendingBlocks
    await pendingBlocks.stop()

  test "Should resolve want handle":
    let
      pendingBlocks = PendingBlocksManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet

    await startWithoutDispatch(pendingBlocks)
    let handle = pendingBlocks.getWantHandle(blk.cid)

    check blk.cid in pendingBlocks
    await pendingBlocks.resolve(
      @[blk].mapIt(BlockDelivery(blk: it, address: it.address))
    )
    await sleepAsync(0.millis)

    # trigger the event loop, otherwise the block finishes before poll runs
    let resolved = await handle
    check resolved.blk == blk
    check resolved.address == blk.address
    check eventually blk.cid notin pendingBlocks
    await pendingBlocks.stop()

  test "Should cancel want handle":
    let
      pendingBlocks = PendingBlocksManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet

    await startWithoutDispatch(pendingBlocks)
    let handle = pendingBlocks.getWantHandle(blk.cid)

    check blk.cid in pendingBlocks
    await handle.cancelAndWait()
    check eventually blk.cid notin pendingBlocks
    await pendingBlocks.stop()

  test "Should isolate shared handle owners":
    let
      pendingBlocks = PendingBlocksManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet

    await startWithoutDispatch(pendingBlocks)
    let handle1 = pendingBlocks.getWantHandle(blk.cid)
    let handle2 = pendingBlocks.getWantHandle(blk.cid)

    check handle1 != handle2
    check pendingBlocks.owners(blk.cid) == 2

    await handle1.cancelAndWait()
    check blk.cid in pendingBlocks
    check eventually pendingBlocks.owners(blk.cid) == 1

    await pendingBlocks.resolve(@[BlockDelivery(blk: blk, address: blk.address)])
    check (await handle2).blk == blk
    await pendingBlocks.stop()

  test "Should cancel all want handles":
    let
      pendingBlocks = PendingBlocksManager.new()
      blks = (0 .. 9).mapIt(bt.Block.new(("Hello " & $it).toBytes).tryGet)

    await startWithoutDispatch(pendingBlocks)
    let handles = blks.mapIt(pendingBlocks.getWantHandle(it.cid))

    pendingBlocks.running = true
    await pendingBlocks.stop()

  test "Should get wants list":
    let
      pendingBlocks = PendingBlocksManager.new()
      blks = (0 .. 9).mapIt(bt.Block.new(("Hello " & $it).toBytes).tryGet)

    await startWithoutDispatch(pendingBlocks)
    discard blks.mapIt(pendingBlocks.getWantHandle(it.cid))

    check:
      blks.mapIt($it.cid).sorted(cmp[string]) ==
        toSeq(pendingBlocks.wantListBlockCids).mapIt($it).sorted(cmp[string])
    await pendingBlocks.stop()

  test "Should handle retry counters":
    let
      pendingBlocks = PendingBlocksManager.new(retries = 3)
      blk = bt.Block.new("Hello".toBytes).tryGet
      address = BlockAddress.init(blk.cid)

    await startWithoutDispatch(pendingBlocks)
    let handle = pendingBlocks.getWantHandle(blk.cid)

    check pendingBlocks.retries(address) == 3
    pendingBlocks.decRetries(address)
    check pendingBlocks.retries(address) == 2
    pendingBlocks.decRetries(address)
    check pendingBlocks.retries(address) == 1
    pendingBlocks.decRetries(address)
    check pendingBlocks.retries(address) == 0
    check pendingBlocks.retriesExhausted(address)
    await pendingBlocks.stop()

suite "PendingBlocks ownership model":
  let
    blk = bt.Block.new("Hello".toBytes).tryGet
    address = BlockAddress.init(blk.cid)

  test "markRequested sets requestedPeer, decrements retries, adds to blocksRequested":
    let
      pb = PendingBlocksManager.new(retries = 5)
      peerCtx = makePeerCtx(makePeerId())

    await startWithoutDispatch(pb)
    discard pb.getWantHandle(address)
    let retriesBefore = pb.retries(address)

    pb.markRequested(address, peerCtx)

    check pb.isRequested(address)
    check pb.retries(address) == retriesBefore - 1
    check pb.getRequestPeer(address) == peerCtx.id.some
    check address in peerCtx.blocksRequested
    await pb.stop()

  test "markRequested is idempotent for same peer":
    let
      pb = PendingBlocksManager.new(retries = 5)
      peerCtx = makePeerCtx(makePeerId())

    await startWithoutDispatch(pb)
    discard pb.getWantHandle(address)
    let retriesBefore = pb.retries(address)

    pb.markRequested(address, peerCtx)
    pb.markRequested(address, peerCtx) # should be a no-op

    check pb.retries(address) == retriesBefore - 1 # only one decrement
    check address in peerCtx.blocksRequested
    await pb.stop()

  test "markRequested is a no-op when requestedPeer is already set":
    let
      pb = PendingBlocksManager.new(retries = 5)
      firstPeer = makePeerCtx(makePeerId())
      secondPeer = makePeerCtx(makePeerId())

    await startWithoutDispatch(pb)
    discard pb.getWantHandle(address)
    let retriesBefore = pb.retries(address)

    pb.markRequested(address, firstPeer)
    pb.markRequested(address, secondPeer) # should be a no-op

    check pb.retries(address) == retriesBefore - 1 # only one decrement
    check pb.getRequestPeer(address) == firstPeer.id.some
    check address in firstPeer.blocksRequested
    check address notin secondPeer.blocksRequested
    await pb.stop()

  test "resolve completes handle and removes from pendingBlocks":
    let pb = PendingBlocksManager.new()

    await startWithoutDispatch(pb)
    let handle = pb.getWantHandle(address)

    discard pb.markRequested(address, peerCtx, 60.seconds)
    check address in peerCtx.blocksRequested

    await pb.resolve(address, blk)
    let delivery = await handle

    check delivery.blk == blk
    check delivery.address == address
    check eventually address notin pb
    await pb.stop()

  test "resolve with sender records delivery on matching peer":
    let
      peerCtx = makePeerCtx(makePeerId())
      pb = PendingBlocksManager.new()

    await startWithoutDispatch(pb)
    discard pb.getWantHandle(address)
    pb.markRequested(address, peerCtx)

    check peerCtx.ensureScoreFor(blk.cid).totalDeliveries == 0

    await pb.resolve(@[BlockDelivery(blk: blk, address: address)], peerCtx.some)

    check peerCtx.ensureScoreFor(blk.cid).totalDeliveries == 1
    check peerCtx.ensureScoreFor(blk.cid).totalBytes == blk.data.len
    check peerCtx.ensureScoreFor(blk.cid).consecutiveFailures == 0
    await pb.stop()

  test "resolve without sender does not record delivery":
    let
      peerCtx = makePeerCtx(makePeerId())
      pb = PendingBlocksManager.new()

    await startWithoutDispatch(pb)
    discard pb.getWantHandle(address)
    pb.markRequested(address, peerCtx)

    check peerCtx.ensureScoreFor(blk.cid).totalDeliveries == 0

    await pb.resolve(@[BlockDelivery(blk: blk, address: address)])

    check peerCtx.ensureScoreFor(blk.cid).totalDeliveries == 0
    check peerCtx.ensureScoreFor(blk.cid).consecutiveFailures == 0
    await pb.stop()

  test "resolve with mismatched sender does not record delivery":
    let
      assignedPeer = makePeerCtx(makePeerId())
      senderPeer = makePeerCtx(makePeerId())
      pb = PendingBlocksManager.new()

    await startWithoutDispatch(pb)
    discard pb.getWantHandle(address)
    pb.markRequested(address, assignedPeer)

    # Delivery from a different peer than the assigned one
    await pb.resolve(@[BlockDelivery(blk: blk, address: address)], senderPeer.some)

    check assignedPeer.ensureScoreFor(blk.cid).totalDeliveries == 0
    check senderPeer.ensureScoreFor(blk.cid).totalDeliveries == 0
    await pb.stop()

  test "failWantHandle fails handle and removes from pendingBlocks":
    let pb = PendingBlocksManager.new()

    await startWithoutDispatch(pb)
    let handle = pb.getWantHandle(address)

    await pb.failWantHandle(address, StorageFailedEngineError, "test error")

    check handle.finished
    check eventually address notin pb
    await pb.stop()

  test "failWantHandle is a no-op on missing block":
    let
      pb = PendingBlocksManager.new()
      missingAddress = BlockAddress.init(bt.Block.new("missing".toBytes).tryGet.cid)

    # Should not raise
    await pb.failWantHandle(missingAddress, StorageFailedEngineError, "no block")

  test "failWantHandle is a no-op on already-finished handle":
    let pb = PendingBlocksManager.new()

    await startWithoutDispatch(pb)
    let handle = pb.getWantHandle(address)

    await pb.resolve(address, blk)
    check eventually handle.finished

    # Should not raise on already-resolved handle
    await pb.failWantHandle(address, StorageFailedEngineError, "already done")
    await pb.stop()

  test "releaseWantHandle decrements owners on cancel":
    let pb = PendingBlocksManager.new()

    await startWithoutDispatch(pb)
    let handle1 = pb.getWantHandle(address)
    let handle2 = pb.getWantHandle(address)

    check pb.owners(address) == 2

    await handle1.cancelAndWait()
    check address in pb # still has one owner
    check eventually pb.owners(address) == 1

    await handle2.cancelAndWait()
    check eventually address notin pb
    await pb.stop()

  test "releaseWantHandle fires onAbandon when last owner cancels":
    var abandonedAddress: Option[BlockAddress]
    let
      onAbandon = proc(a: BlockAddress) {.gcsafe, async: (raises: [CancelledError]).} =
        abandonedAddress = a.some
      pb = PendingBlocksManager.new(onAbandon = onAbandon)

    await startWithoutDispatch(pb)
    let handle = pb.getWantHandle(address)
    await handle.cancelAndWait()

    check eventually address notin pb
    check eventually abandonedAddress == address.some
    await pb.stop()

suite "PendingBlocks dispatch monitor":
  let
    blk = bt.Block.new("Hello".toBytes).tryGet
    address = BlockAddress.init(blk.cid)

  test "getWantHandle dispatches via monitor when running":
    let
      pb = PendingBlocksManager.new(batchDeadline = 1.millis)
      peerCtx = makePeerCtx(makePeerId())
      sent = newAsyncEvent()

    pb.sendBatch = proc(
        peer: BlockExcPeerCtx, batch: seq[BlockAddress]
    ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
      sent.fire()
      success()

    pb.getPeerForBlock = alwaysPeer(peerCtx)

    await pb.start()

    let handle = pb.getWantHandle(address)
    await sent.wait().wait(1.seconds)
    check eventually pb.isRequested(address)
    check address in peerCtx.blocksRequested

    await handle.cancelAndWait()
    await pb.stop()

  test "monitor requeues on Requeue selection":
    let
      pb =
        PendingBlocksManager.new(discoveryTimeout = 5.seconds, batchDeadline = 1.millis)
      peerCtx = makePeerCtx(makePeerId())
      sent = newAsyncEvent()
      requeued = newAsyncEvent()

    var selectorCalls = 0
    pb.sendBatch = proc(
        peer: BlockExcPeerCtx, batch: seq[BlockAddress]
    ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
      sent.fire()
      success()

    pb.getPeerForBlock = proc(
        a: BlockAddress
    ): Future[?!PeerSelection] {.async: (raises: [CancelledError]), gcsafe.} =
      selectorCalls.inc()
      if selectorCalls == 1:
        requeued.fire()
        success PeerSelection(kind: PeerSelectionKind.Requeue, delay: 10.millis)
      else:
        success PeerSelection(kind: PeerSelectionKind.Peer, peer: peerCtx)

    await pb.start()
    discard pb.getWantHandle(address)

    await requeued.wait().wait(1.seconds)
    await sent.wait().wait(2.seconds)
    check eventually pb.isRequested(address)

    await pb.stop()

  test "monitor records failure on real timeout":
    let
      pb = PendingBlocksManager.new(
        batchDeadline = 1.millis,
        discoveryTimeout = 50.millis,
        blockSendTimeout = 50.millis,
      )
      peerCtx = makePeerCtx(makePeerId())
      sent = newAsyncEvent()
      timedOut = newAsyncEvent()

    pb.sendBatch = proc(
        peer: BlockExcPeerCtx, batch: seq[BlockAddress]
    ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
      sent.fire()
      success()

    pb.getPeerForBlock = alwaysPeer(peerCtx)
    pb.onTimeout = proc(
        address: BlockAddress, peer: PeerId
    ) {.gcsafe, async: (raises: [CancelledError]).} =
      timedOut.fire()

    await pb.start()
    discard pb.getWantHandle(address)

    await sent.wait().wait(100.millis)
    check pb.isRequested(address)

    # Real timeout: peer stays connected, blockSendTimeout fires.
    await timedOut.wait().wait(200.millis)

    check eventually (not pb.isRequested(address))
    check peerCtx.ensureScoreFor(blk.cid).consecutiveFailures >= 1

    await pb.stop()

  test "monitor clears assignment on disconnect without onTimeout":
    let
      pb = PendingBlocksManager.new(
        batchDeadline = 1.millis,
        discoveryTimeout = 50.millis,
        blockSendTimeout = 30.seconds,
      )
      peerCtx = makePeerCtx(makePeerId())
      sent = newAsyncEvent()
      timedOut = newAsyncEvent()

    pb.sendBatch = proc(
        peer: BlockExcPeerCtx, batch: seq[BlockAddress]
    ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
      sent.fire()
      success()

    pb.getPeerForBlock = alwaysPeer(peerCtx)
    pb.onTimeout = proc(
        address: BlockAddress, peer: PeerId
    ) {.gcsafe, async: (raises: [CancelledError]).} =
      timedOut.fire()

    await pb.start()
    let handle = pb.getWantHandle(address)
    await sent.wait().wait(100.millis)
    check pb.isRequested(address)

    peerCtx.disconnect()
    check eventually (not pb.isRequested(address))
    check eventually peerCtx.id notin pb.byPeer
    check not timedOut.isSet

    await handle.cancelAndWait()
    await pb.stop()

  test "monitor handles peer disconnect during in-flight":
    let
      pb = PendingBlocksManager.new(
        batchDeadline = 1.millis,
        discoveryTimeout = 50.millis,
        blockSendTimeout = 30.seconds,
      )
      peerCtx = makePeerCtx(makePeerId())
      sent = newAsyncEvent()

    pb.sendBatch = proc(
        peer: BlockExcPeerCtx, batch: seq[BlockAddress]
    ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
      sent.fire()
      success()

    pb.getPeerForBlock = alwaysPeer(peerCtx)

    await pb.start()
    let handle = pb.getWantHandle(address)
    await sent.wait().wait(100.millis)
    check pb.isRequested(address)

    peerCtx.disconnect()
    check eventually (not pb.isRequested(address))
    check eventually peerCtx.id notin pb.byPeer

    await handle.cancelAndWait()
    await pb.stop()

  test "send failure does not markRequested":
    let
      pb = PendingBlocksManager.new(
        discoveryTimeout = 5.millis, batchDeadline = 1.millis, retries = 10
      )
      peerCtx = makePeerCtx(makePeerId())
      gate = newAsyncEvent()
      batchSent = newAsyncEvent()

    var sendCount = 0
    pb.sendBatch = proc(
        peer: BlockExcPeerCtx, batch: seq[BlockAddress]
    ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
      sendCount.inc()
      if sendCount == 1:
        failure(newException(CatchableError, "send failed"))
      else:
        batchSent.fire()
        success()

    var selectorCalls = 0
    pb.getPeerForBlock = proc(
        a: BlockAddress
    ): Future[?!PeerSelection] {.async: (raises: [CancelledError]), gcsafe.} =
      selectorCalls.inc()
      if selectorCalls >= 2:
        await gate.wait()
      success PeerSelection(kind: PeerSelectionKind.Peer, peer: peerCtx)

    await pb.start()
    discard pb.getWantHandle(address)

    # Wait for first send to fail and monitor to loop back.
    check eventually selectorCalls >= 2

    # After first failed send: no assignment, no blocksRequested, retries unchanged.
    check sendCount == 1
    check not pb.isRequested(address)
    check address notin peerCtx.blocksRequested
    check pb.retries(address) == 10

    # Release gate for retry.
    gate.fire()
    await batchSent.wait().wait(5.seconds)

    # After successful retry: marked once, retries decremented once.
    check sendCount == 2
    check eventually pb.isRequested(address)
    check address in peerCtx.blocksRequested
    check pb.retries(address) == 9

    await pb.stop()

  test "wakeAddress fires wakeEvent and re-dispatches":
    let
      pb = PendingBlocksManager.new(
        discoveryTimeout = 30.seconds, batchDeadline = 1.millis
      )
      peerCtx = makePeerCtx(makePeerId())
      sent = newAsyncEvent()
      gate = newAsyncEvent()

    var selectorCalls = 0
    pb.sendBatch = proc(
        peer: BlockExcPeerCtx, batch: seq[BlockAddress]
    ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
      sent.fire()
      success()

    pb.getPeerForBlock = proc(
        a: BlockAddress
    ): Future[?!PeerSelection] {.async: (raises: [CancelledError]), gcsafe.} =
      selectorCalls.inc()
      if selectorCalls == 1:
        success PeerSelection(kind: PeerSelectionKind.Requeue, delay: 30.seconds)
      else:
        await gate.wait()
        success PeerSelection(kind: PeerSelectionKind.Peer, peer: peerCtx)

    await pb.start()
    discard pb.getWantHandle(address)

    check eventually selectorCalls == 1

    # Wake should fire the event and let monitor reselect before the 30s delay.
    check pb.wakeAddress(address)
    check eventually selectorCalls == 2

    gate.fire()
    await sent.wait().wait(2.seconds)
    check eventually pb.isRequested(address)

    await pb.stop()

  test "wakeAddress returns false for missing block":
    let pb = PendingBlocksManager.new()
    let missingAddress = BlockAddress.init(bt.Block.new("missing".toBytes).tryGet.cid)
    check not pb.wakeAddress(missingAddress)

  test "wakeAddress returns false for finished handle":
    let pb = PendingBlocksManager.new()

    await startWithoutDispatch(pb)
    let handle = pb.getWantHandle(address)

    await pb.resolve(address, blk)
    check eventually handle.finished

    check not pb.wakeAddress(address)
    await pb.stop()

  test "wakeAddress returns false for assigned request":
    let
      pb = PendingBlocksManager.new(retries = 5)
      peerCtx = makePeerCtx(makePeerId())

    await startWithoutDispatch(pb)
    discard pb.getWantHandle(address)
    pb.markRequested(address, peerCtx)

    check not pb.wakeAddress(address)
    check pb.isRequested(address)
    await pb.stop()

  test "rejectRequest clears assignment and fires wakeEvent":
    let
      pb = PendingBlocksManager.new(retries = 5)
      peerCtx = makePeerCtx(makePeerId())
      peerId = peerCtx.id

    await startWithoutDispatch(pb)
    discard pb.getWantHandle(address)
    pb.markRequested(address, peerCtx)

    check pb.isRequested(address)

    check pb.rejectRequest(address, peerCtx)

    check not pb.isRequested(address)
    check address notin peerCtx.blocksRequested
    check pb.getRequestPeer(address) == PeerId.none
    await pb.stop()

  test "rejectRequest is a no-op for wrong peer":
    let
      pb = PendingBlocksManager.new(retries = 5)
      firstPeer = makePeerCtx(makePeerId())
      secondPeer = makePeerCtx(makePeerId())

    await startWithoutDispatch(pb)
    discard pb.getWantHandle(address)
    pb.markRequested(address, firstPeer)

    check not pb.rejectRequest(address, secondPeer)

    check pb.isRequested(address)
    check pb.getRequestPeer(address) == firstPeer.id.some
    await pb.stop()

  test "rejectRequest is a no-op for missing block":
    let
      pb = PendingBlocksManager.new()
      peerCtx = makePeerCtx(makePeerId())
      missingAddress = BlockAddress.init(bt.Block.new("missing".toBytes).tryGet.cid)

    check not pb.rejectRequest(missingAddress, peerCtx)

  test "monitor retries on send failure then succeeds":
    let
      pb =
        PendingBlocksManager.new(discoveryTimeout = 5.millis, batchDeadline = 1.millis)
      peerCtx = makePeerCtx(makePeerId())
      successEvent = newAsyncEvent()

    var sendCount = 0
    pb.sendBatch = proc(
        peer: BlockExcPeerCtx, batch: seq[BlockAddress]
    ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
      sendCount.inc()
      if sendCount == 1:
        failure(newException(CatchableError, "first send fails"))
      else:
        successEvent.fire()
        success()

    pb.getPeerForBlock = alwaysPeer(peerCtx)

    await pb.start()
    discard pb.getWantHandle(address)

    await successEvent.wait().wait(5.seconds)
    check sendCount >= 2
    check eventually pb.isRequested(address)

    await pb.stop()

  test "monitor fails with RetriesExhaustedEngineError when retries hit 0":
    let
      pb = PendingBlocksManager.new(retries = 1, discoveryTimeout = 5.millis)
      peerCtx = makePeerCtx(makePeerId())

    pb.sendBatch = nopSendBatch
    pb.getPeerForBlock = alwaysRequeue(1.millis)

    await pb.start()
    let handle = pb.getWantHandle(address)

    pb.blocks[address].retries = 0

    check eventually handle.finished
    expect EngineError:
      discard await handle

    await pb.stop()

  test "monitor handles concurrent blocks independently":
    let
      pb = PendingBlocksManager.new(batchDeadline = 1.millis)
      peerCtx = makePeerCtx(makePeerId())
      blk2 = bt.Block.new("World".toBytes).tryGet
      address2 = BlockAddress.init(blk2.cid)

    var sentAddresses: seq[BlockAddress] = @[]
    let bothSent = newAsyncEvent()

    pb.sendBatch = proc(
        peer: BlockExcPeerCtx, batch: seq[BlockAddress]
    ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
      for address in batch:
        sentAddresses.add(address)
      if sentAddresses.len >= 2 and not bothSent.isSet:
        bothSent.fire()
      success()

    pb.getPeerForBlock = alwaysPeer(peerCtx)

    await pb.start()
    discard pb.getWantHandle(address)
    discard pb.getWantHandle(address2)

    await bothSent.wait().wait(2.seconds)
    check address in sentAddresses
    check address2 in sentAddresses
    check eventually pb.isRequested(address)
    check eventually pb.isRequested(address2)

    await pb.stop()

  test "Batch worker dispatches and marks requested via deliver":
    let
      pb = PendingBlocksManager.new(batchSize = 2, batchDeadline = 50.millis)
      peerCtx = makePeerCtx(makePeerId())
      dispatched = newAsyncEvent()

    pb.sendBatch = proc(
        peer: BlockExcPeerCtx, batch: seq[BlockAddress]
    ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
      dispatched.fire()
      success()

    pb.getPeerForBlock = alwaysPeer(peerCtx)

    await pb.start()
    discard pb.getWantHandle(address)

    await dispatched.wait().wait(2.seconds)
    check eventually pb.isRequested(address)
    await pb.stop()

  test "simultaneous dispatch and disconnect":
    let
      pb = PendingBlocksManager.new(
        batchDeadline = 1.millis,
        discoveryTimeout = 50.millis,
        blockSendTimeout = 30.seconds,
      )
      peerCtx = makePeerCtx(makePeerId())
      sent = newAsyncEvent()
      resent = newAsyncEvent()

    var selectorCalls = 0
    pb.sendBatch = proc(
        peer: BlockExcPeerCtx, batch: seq[BlockAddress]
    ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
      sent.fire()
      # Disconnect peer inside the send handler before it returns.
      if not peerCtx.isDisconnected:
        peerCtx.disconnect()
      success()

    pb.getPeerForBlock = proc(
        a: BlockAddress
    ): Future[?!PeerSelection] {.async: (raises: [CancelledError]), gcsafe.} =
      selectorCalls.inc()
      if selectorCalls >= 2:
        resent.fire()
      success PeerSelection(kind: PeerSelectionKind.Peer, peer: peerCtx)

    await pb.start()
    let handle = pb.getWantHandle(address)

    await sent.wait().wait(1.seconds)
    # Worker marked/fired despite concurrent disconnect.
    check eventually pb.isRequested(address)

    # Post-send disconnect path clears assignment and monitor selects a replacement.
    check eventually (not pb.isRequested(address))
    check eventually selectorCalls >= 2

    await handle.cancelAndWait()
    await pb.stop()

  test "same-PeerId reconnect replaces stale worker":
    let
      pid = makePeerId()
      ctx1 = makePeerCtx(pid)
      ctx2 = makePeerCtx(pid)
      pb = PendingBlocksManager.new(
        batchDeadline = 1.millis,
        discoveryTimeout = 50.millis,
        blockSendTimeout = 30.seconds,
      )
      firstSent = newAsyncEvent()
      secondSent = newAsyncEvent()

    var selectorCalls = 0
    pb.sendBatch = proc(
        peer: BlockExcPeerCtx, batch: seq[BlockAddress]
    ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
      if peer == ctx1:
        firstSent.fire()
      elif peer == ctx2:
        secondSent.fire()
      success()

    pb.getPeerForBlock = proc(
        a: BlockAddress
    ): Future[?!PeerSelection] {.async: (raises: [CancelledError]), gcsafe.} =
      selectorCalls.inc()
      if selectorCalls == 1:
        success PeerSelection(kind: PeerSelectionKind.Peer, peer: ctx1)
      else:
        success PeerSelection(kind: PeerSelectionKind.Peer, peer: ctx2)

    await pb.start()
    let handle = pb.getWantHandle(address)

    await firstSent.wait().wait(1.seconds)
    check eventually pb.getRequestPeerCtx(address) == ctx1

    # Disconnect ctx1 — monitor clears assignment and reselects ctx2.
    ctx1.disconnect()
    await secondSent.wait().wait(2.seconds)

    # Stale worker replaced; batch sends through ctx2.
    check eventually pb.getRequestPeerCtx(address) == ctx2

    await handle.cancelAndWait()
    await pb.stop()

  test "identity-guard: delayed cleanup does not cancel replacement":
    let
      pid = makePeerId()
      ctx1 = makePeerCtx(pid)
      ctx2 = makePeerCtx(pid)
      pb = PendingBlocksManager.new(
        batchDeadline = 1.millis,
        discoveryTimeout = 50.millis,
        blockSendTimeout = 30.seconds,
      )
      ctx2Dispatched = newAsyncEvent()

    var selectorCalls = 0
    pb.sendBatch = proc(
        peer: BlockExcPeerCtx, batch: seq[BlockAddress]
    ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
      if peer == ctx2:
        ctx2Dispatched.fire()
      success()

    pb.getPeerForBlock = proc(
        a: BlockAddress
    ): Future[?!PeerSelection] {.async: (raises: [CancelledError]), gcsafe.} =
      selectorCalls.inc()
      if selectorCalls == 1:
        success PeerSelection(kind: PeerSelectionKind.Peer, peer: ctx1)
      else:
        success PeerSelection(kind: PeerSelectionKind.Peer, peer: ctx2)

    await pb.start()
    let handle = pb.getWantHandle(address)

    # Wait for ctx1 to be dispatched.
    check eventually selectorCalls >= 1
    check eventually pb.isRequested(address)

    # Disconnect ctx1 — monitor clears, reselects ctx2.
    ctx1.disconnect()

    # ctx2 batch sends through; its worker is not cancelled by ctx1's cleanup.
    await ctx2Dispatched.wait().wait(2.seconds)
    check eventually pb.getRequestPeerCtx(address) == ctx2

    await handle.cancelAndWait()
    await pb.stop()

  test "idle worker exits on disconnect":
    let
      pb = PendingBlocksManager.new(batchDeadline = 1.millis)
      peerCtx = makePeerCtx(makePeerId())
      sent = newAsyncEvent()

    pb.sendBatch = proc(
        peer: BlockExcPeerCtx, batch: seq[BlockAddress]
    ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
      sent.fire()
      success()

    pb.getPeerForBlock = alwaysPeer(peerCtx)

    await pb.start()
    let handle = pb.getWantHandle(address)
    await sent.wait().wait(1.seconds)
    check eventually pb.isRequested(address)

    # Resolve the block — worker stays alive, blocked on next pipe.get().
    await pb.resolve(address, blk)
    check eventually handle.finished
    check peerCtx.id in pb.byPeer

    # Disconnect — idle worker should exit and clean up byPeer.
    peerCtx.disconnect()
    check eventually peerCtx.id notin pb.byPeer

    await pb.stop()

suite "PendingBlocks start/stop":
  let
    blk = bt.Block.new("Hello".toBytes).tryGet
    address = BlockAddress.init(blk.cid)

  test "start is idempotent":
    let pb = PendingBlocksManager.new()
    await pb.start()
    await pb.start() # should not raise
    check pb.running
    await pb.stop()

  test "stop is idempotent":
    let pb = PendingBlocksManager.new()
    await pb.start()
    await pb.stop()
    await pb.stop() # should not raise
    check not pb.running

  test "stop clears all state":
    let
      pb = PendingBlocksManager.new()
      peerCtx = makePeerCtx(makePeerId())

    pb.sendBatch = nopSendBatch
    pb.getPeerForBlock = alwaysPeer(peerCtx)

    await pb.start()
    discard pb.getWantHandle(address)
    await pb.stop()

    check pb.len == 0
    check pb.byPeer.len == 0
    check pb.handles.len == 0

  test "stop cancels in-flight monitors":
    let
      pb = PendingBlocksManager.new(
        batchDeadline = 1.millis, discoveryTimeout = 30.seconds
      )
      peerCtx = makePeerCtx(makePeerId())

    pb.sendBatch = nopSendBatch
    pb.getPeerForBlock = alwaysRequeue(30.seconds)

    await pb.start()
    let handle = pb.getWantHandle(address)
    await sleepAsync(50.millis) # let monitor enter requeue sleep

    await pb.stop()

    # Handle should be finished after stop (cancellation only).
    check eventually handle.finished
    expect CatchableError:
      discard await handle

  test "getWantHandle raises when not started":
    let
      pb = PendingBlocksManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet

    expect AssertionDefect:
      discard pb.getWantHandle(blk.cid)

  test "stop on already-stopped manager leaves tracked futures untouched":
    let pb = PendingBlocksManager.new()

    let sentinel =
      Future[void].Raising([]).init("stop guard", {FutureFlag.OwnCancelSchedule})
    pb.trackedFutures.track(sentinel)

    await pb.stop() # running is false, should early-return

    check not sentinel.finished

    sentinel.complete() # cleanup

suite "PendingBlocks batching":
  let
    blk = bt.Block.new("Hello".toBytes).tryGet
    address = BlockAddress.init(blk.cid)

  test "batch groups multiple blocks to same peer":
    let
      pb = PendingBlocksManager.new(batchSize = 10, batchDeadline = 5.millis)
      peerCtx = makePeerCtx(makePeerId())
      blk2 = bt.Block.new("Second".toBytes).tryGet
      blk3 = bt.Block.new("Third".toBytes).tryGet
      address2 = BlockAddress.init(blk2.cid)
      address3 = BlockAddress.init(blk3.cid)
      batchDone = newAsyncEvent()

    var batches: seq[seq[BlockAddress]] = @[]
    pb.sendBatch = proc(
        peer: BlockExcPeerCtx, batch: seq[BlockAddress]
    ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
      batches.add(batch)
      if batches.len == 1:
        batchDone.fire()
      success()

    pb.getPeerForBlock = alwaysPeer(peerCtx)

    await pb.start()
    discard pb.getWantHandle(address)
    discard pb.getWantHandle(address2)
    discard pb.getWantHandle(address3)

    await batchDone.wait().wait(2.seconds)

    # Require at least one batch containing all three addresses.
    var foundAll = false
    for batch in batches:
      if address in batch and address2 in batch and address3 in batch:
        foundAll = true
        break
    check foundAll

    await pb.stop()

  test "deadline expiry dispatches partial batch":
    let
      pb = PendingBlocksManager.new(batchSize = 10, batchDeadline = 1.millis)
      peerCtx = makePeerCtx(makePeerId())
      blk2 = bt.Block.new("Second".toBytes).tryGet
      address2 = BlockAddress.init(blk2.cid)
      firstBatch = newAsyncEvent()
      secondBatch = newAsyncEvent()

    var batchCount = 0
    pb.sendBatch = proc(
        peer: BlockExcPeerCtx, batch: seq[BlockAddress]
    ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
      batchCount.inc()
      if batchCount == 1:
        firstBatch.fire()
      else:
        secondBatch.fire()
      success()

    pb.getPeerForBlock = alwaysPeer(peerCtx)

    await pb.start()

    # Send first block — batch starts, deadline fires quickly
    discard pb.getWantHandle(address)
    await firstBatch.wait().wait(1.seconds)

    # Send second block — new batch
    discard pb.getWantHandle(address2)
    await secondBatch.wait().wait(1.seconds)

    check batchCount >= 2

    await pb.stop()
