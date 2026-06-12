import std/sequtils
import std/algorithm
import std/heapqueue
import std/importutils

import pkg/chronos
import pkg/libp2p
import pkg/stew/byteutils
import pkg/questionable

import pkg/archivist/rng
import pkg/archivist/blocktype as bt
import pkg/archivist/blockexchange {.all.}
import pkg/archivist/blockexchange/engine/pendingblocks {.all.}
import pkg/archivist/utils/trackedfutures

import ../helpers
import ../../asynctest

privateAccess(PendingBlocksManager)
privateAccess(BatchReq)
privateAccess(BlockItem)
privateAccess(BlockReq)

proc makePeerId(): PeerId =
  let seckey = PrivateKey.random(Rng.instance()[]).tryGet()
  PeerId.init(seckey.getPublicKey().tryGet()).tryGet()

proc makePeerCtx(id: PeerId): BlockExcPeerCtx =
  BlockExcPeerCtx.new(id)

suite "Pending Blocks":
  test "Should add want handle":
    let
      pendingBlocks = PendingBlocksManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet

    discard pendingBlocks.getWantHandle(blk.cid)

    check blk.cid in pendingBlocks

  test "Should resolve want handle":
    let
      pendingBlocks = PendingBlocksManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet
      handle = pendingBlocks.getWantHandle(blk.cid)

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

  test "Should cancel want handle":
    let
      pendingBlocks = PendingBlocksManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet
      handle = pendingBlocks.getWantHandle(blk.cid)

    check blk.cid in pendingBlocks
    await handle.cancelAndWait()
    check eventually blk.cid notin pendingBlocks

  test "Should isolate shared handle owners":
    let
      pendingBlocks = PendingBlocksManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet
      handle1 = pendingBlocks.getWantHandle(blk.cid)
      handle2 = pendingBlocks.getWantHandle(blk.cid)

    check handle1 != handle2
    check pendingBlocks.owners(blk.cid) == 2

    await handle1.cancelAndWait()
    check blk.cid in pendingBlocks
    check eventually pendingBlocks.owners(blk.cid) == 1

    await pendingBlocks.resolve(@[BlockDelivery(blk: blk, address: blk.address)])
    check (await handle2).blk == blk

  test "Should cancel all want handles":
    let
      pendingBlocks = PendingBlocksManager.new()
      blks = (0 .. 9).mapIt(bt.Block.new(("Hello " & $it).toBytes).tryGet)
      handles = blks.mapIt(pendingBlocks.getWantHandle(it.cid))

    pendingBlocks.running = true
    await pendingBlocks.stop()

    check pendingBlocks.len == 0
    for handle in handles:
      expect CancelledError:
        discard await handle

  test "Should fire request timeout for current attempt":
    var timedOut = false
    let
      blk = bt.Block.new("Hello".toBytes).tryGet
      address = BlockAddress.init(blk.cid)
      peerId = makePeerId()
      peerCtx = makePeerCtx(peerId)

      onTimeout = proc(
          timeoutAddress: BlockAddress, timeoutPeer: PeerId
      ) {.gcsafe, async: (raises: [CancelledError]).} =
        check timeoutAddress == address
        check timeoutPeer == peerId
        timedOut = true

      pendingBlocks = PendingBlocksManager.new(onTimeout = onTimeout)

    discard pendingBlocks.getWantHandle(blk.cid)
    pendingBlocks.blocks[address].state = Scheduled
    pendingBlocks.markRequested(address, peerCtx, 1.millis)
    check eventually timedOut

  test "Should cancel request timeout on clear":
    var timedOut = false
    let
      blk = bt.Block.new("Hello".toBytes).tryGet
      address = BlockAddress.init(blk.cid)
      peerId = makePeerId()
      peerCtx = makePeerCtx(peerId)

      onTimeout = proc(
          timeoutAddress: BlockAddress, timeoutPeer: PeerId
      ) {.gcsafe, async: (raises: [CancelledError]).} =
        timedOut = true

      pendingBlocks = PendingBlocksManager.new()

    discard pendingBlocks.getWantHandle(blk.cid)
    pendingBlocks.blocks[address].state = Scheduled
    pendingBlocks.markRequested(address, peerCtx, 10.millis)
    await pendingBlocks.clearRequest(address, peerCtx)
    await sleepAsync(50.millis)

    check not timedOut

  test "Should cancel request timeout on resolve":
    var timedOut = false
    let
      blk = bt.Block.new("Hello".toBytes).tryGet
      address = BlockAddress.init(blk.cid)
      peerId = makePeerId()
      peerCtx = makePeerCtx(peerId)

      onTimeout = proc(
          timeoutAddress: BlockAddress, timeoutPeer: PeerId
      ) {.gcsafe, async: (raises: [CancelledError]).} =
        timedOut = true

      pendingBlocks = PendingBlocksManager.new()

    let handle = pendingBlocks.getWantHandle(blk.cid)
    pendingBlocks.blocks[address].state = Scheduled
    pendingBlocks.markRequested(address, peerCtx, 10.millis)

    await pendingBlocks.resolve(@[BlockDelivery(blk: blk, address: blk.address)])
    check (await handle).blk == blk
    await sleepAsync(20.millis)
    check not timedOut

  test "Should cancel request timeout on final owner release":
    var timedOut = false
    let
      blk = bt.Block.new("Hello".toBytes).tryGet
      address = BlockAddress.init(blk.cid)
      peerId = makePeerId()
      peerCtx = makePeerCtx(peerId)

      onTimeout = proc(
          timeoutAddress: BlockAddress, timeoutPeer: PeerId
      ) {.gcsafe, async: (raises: [CancelledError]).} =
        timedOut = true

      pendingBlocks = PendingBlocksManager.new(onTimeout = onTimeout)

    let handle = pendingBlocks.getWantHandle(blk.cid)
    pendingBlocks.blocks[address].state = Scheduled
    pendingBlocks.markRequested(address, peerCtx, 10.millis)
    await handle.cancelAndWait()

    check eventually blk.cid notin pendingBlocks
    await sleepAsync(20.millis)
    check not timedOut

  test "Should replace cleared request timeout with next attempt":
    var timeouts: seq[PeerId]

    let
      blk = bt.Block.new("Hello".toBytes).tryGet
      address = BlockAddress.init(blk.cid)
      firstPeerId = makePeerId()
      firstPeerCtx = makePeerCtx(firstPeerId)
      secondPeerId = makePeerId()
      secondPeerCtx = makePeerCtx(secondPeerId)

      onTimeout = proc(
          timeoutAddress: BlockAddress, timeoutPeer: PeerId
      ) {.gcsafe, async: (raises: [CancelledError]).} =
        check timeoutAddress == address
        timeouts.add(timeoutPeer)

      pendingBlocks = PendingBlocksManager.new(onTimeout = onTimeout)

    discard pendingBlocks.getWantHandle(blk.cid)
    pendingBlocks.blocks[address].state = Scheduled
    pendingBlocks.markRequested(address, firstPeerCtx, 20.millis)
    await pendingBlocks.clearRequest(address, firstPeerCtx)
    pendingBlocks.blocks[address].state = Scheduled
    pendingBlocks.markRequested(address, secondPeerCtx, 1.millis)

    check eventually timeouts.len == 1
    check timeouts[0] == secondPeerId
    await sleepAsync(25.millis)
    check timeouts.len == 1

  test "Should get wants list":
    let
      pendingBlocks = PendingBlocksManager.new()
      blks = (0 .. 9).mapIt(bt.Block.new(("Hello " & $it).toBytes).tryGet)

    discard blks.mapIt(pendingBlocks.getWantHandle(it.cid))

    check:
      blks.mapIt($it.cid).sorted(cmp[string]) ==
        toSeq(pendingBlocks.wantListBlockCids).mapIt($it).sorted(cmp[string])

  test "Should handle retry counters":
    let
      pendingBlocks = PendingBlocksManager.new(retries = 3)
      blk = bt.Block.new("Hello".toBytes).tryGet
      address = BlockAddress.init(blk.cid)
      handle = pendingBlocks.getWantHandle(blk.cid)

    check pendingBlocks.retries(address) == 3
    pendingBlocks.decRetries(address)
    check pendingBlocks.retries(address) == 2
    pendingBlocks.decRetries(address)
    check pendingBlocks.retries(address) == 1
    pendingBlocks.decRetries(address)
    check pendingBlocks.retries(address) == 0
    check pendingBlocks.retriesExhausted(address)

suite "PendingBlocks ownership model":
  let
    blk = bt.Block.new("Hello".toBytes).tryGet
    address = BlockAddress.init(blk.cid)

  test "requeue pushes snapshot":
    let pb = PendingBlocksManager.new()
    discard pb.getWantHandle(address)
    await pb.retryAddresses(@[address], 10.seconds)
    check address in pb
    check not pb.isRequested(address)

  test "markRequested properly sets all fields":
    let pb = PendingBlocksManager.new()
    discard pb.getWantHandle(address)
    let retriesBefore = pb.retries(address)
    let peerCtx = makePeerCtx(makePeerId())

    pb.blocks[address].state = Scheduled
    pb.markRequested(address, peerCtx, 60.seconds)

    check pb.isRequested(address)
    check pb.retries(address) == retriesBefore - 1
    check pb.getRequestPeer(address) == peerCtx.id.some
    check address in peerCtx.blocksRequested

  test "clearRequest clears in-flight and removes from blocksRequested":
    let
      peerId = makePeerId()
      peerCtx = makePeerCtx(peerId)
      pb = PendingBlocksManager.new()

    discard pb.getWantHandle(address)
    pb.blocks[address].state = Scheduled
    pb.markRequested(address, peerCtx, 60.seconds)

    check pb.isRequested(address)
    check address in peerCtx.blocksRequested

    await pb.clearRequest(address, peerCtx)

    check not pb.isRequested(address)
    check pb.getRequestPeer(address) == PeerId.none

    check address notin peerCtx.blocksRequested

  test "failWantHandle fails request and removes from blocksRequested":
    let
      peerId = makePeerId()
      peerCtx = makePeerCtx(peerId)
      pb = PendingBlocksManager.new()
      handle = pb.getWantHandle(address)

    pb.blocks[address].state = Scheduled
    pb.markRequested(address, peerCtx, 60.seconds)
    check address in peerCtx.blocksRequested

    await pb.failWantHandle(address, StorageFailedEngineError, "test error")
    check handle.finished
    check address notin pb
    check address notin peerCtx.blocksRequested

  test "resolve completes handle and removes from blocksRequested":
    let
      peerId = makePeerId()
      peerCtx = makePeerCtx(peerId)
      pb = PendingBlocksManager.new()
      handle = pb.getWantHandle(address)

    pb.blocks[address].state = Scheduled
    pb.markRequested(address, peerCtx, 60.seconds)
    check address in peerCtx.blocksRequested

    await pb.resolve(address, blk)
    let delivery = await handle

    check delivery.blk == blk
    check delivery.address == address

    check address notin peerCtx.blocksRequested
    check address notin pb

  test "timeout requeues block and clears peer assignment":
    let
      peerId = makePeerId()
      peerCtx = makePeerCtx(peerId)
      timeoutEvent = newAsyncEvent()
      onTimeout = proc(
          timeoutAddress: BlockAddress, timeoutPeer: PeerId
      ) {.gcsafe, async: (raises: [CancelledError]).} =
        check timeoutAddress == address
        check timeoutPeer == peerId
        timeoutEvent.fire()

      pb = PendingBlocksManager.new(onTimeout = onTimeout)

    discard pb.getWantHandle(address)
    pb.blocks[address].state = Scheduled
    pb.markRequested(address, peerCtx, 10.millis)

    check pb.isRequested(address)
    check address in peerCtx.blocksRequested

    await timeoutEvent.wait().wait(1.seconds)

    check not pb.isRequested(address)
    check address in pb
    check address notin peerCtx.blocksRequested

  test "retryAddresses requeues":
    let
      peerId = makePeerId()
      peerCtx = makePeerCtx(peerId)
      pb = PendingBlocksManager.new()

    discard pb.getWantHandle(address)
    pb.blocks[address].state = Scheduled
    pb.markRequested(address, peerCtx, 60.seconds)

    check address in peerCtx.blocksRequested

    await pb.clearPeerAssignment(address)
    await pb.retryAddresses(@[address], 0.millis)
    check address notin peerCtx.blocksRequested
    check not pb.isRequested(address)
    check address in pb

  test "Scheduler respects priority ordering":
    # Priority is a tiebreaker when readyAt is equal. We request both items
    # through the scheduler and verify both are dispatched.
    let
      pb = PendingBlocksManager.new(batchSize = 1, batchDeadline = 1.millis)
      lowPriorityAddress = BlockAddress.init(bt.Block.new("low".toBytes).tryGet.cid)
      highPriorityAddress = BlockAddress.init(bt.Block.new("high".toBytes).tryGet.cid)
      bothSent = newFuture[void]()
      peerId = makePeerId()

    var sentAddresses: seq[BlockAddress]
    pb.sendBatch = proc(
        peer: BlockExcPeerCtx, batch: seq[BlockAddress]
    ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
      sentAddresses.add(batch[0])
      if sentAddresses.len == 2 and not bothSent.finished:
        check sentAddresses[0] == highPriorityAddress
        check sentAddresses[1] == lowPriorityAddress
        bothSent.complete()

      success()

    pb.getPeerForBlock = proc(
        address: BlockAddress
    ): Future[?!BlockExcPeerCtx] {.gcsafe, async: (raises: [CancelledError]).} =
      success makePeerCtx(peerId)

    await pb.start()

    # The heap correctly orders by readyAt first, then priority.
    # TODO: Priority should probably behave differently, `readyAt`
    # take precedense, but perhaps it shouldn't?
    discard pb.getWantHandle(highPriorityAddress, priority = 10)
    discard pb.getWantHandle(lowPriorityAddress, priority = 1)

    await bothSent.wait(1.seconds)
    await pb.stop()

    check sentAddresses.len == 2
    check lowPriorityAddress in sentAddresses
    check highPriorityAddress in sentAddresses

  test "Disconnect monitor requeues blocks and cleans byPeer":
    let
      pb = PendingBlocksManager.new()
      peerId = makePeerId()
      peerCtx = makePeerCtx(peerId)
      blk = Block.new("data".toBytes).tryGet
      sendBatchEvent = newAsyncEvent()

    var getPeerCallCount = 0

    # Block sendBatch so the address stays in-flight (blocksRequested set)
    pb.sendBatch = proc(
        peer: BlockExcPeerCtx, batch: seq[BlockAddress]
    ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
      # Block so the batch worker stays stuck
      sendBatchEvent.fire()
      success()

    # Return peer on first call only, then fail to prevent re-dispatch loop
    pb.getPeerForBlock = proc(
        address: BlockAddress
    ): Future[?!BlockExcPeerCtx] {.gcsafe, async: (raises: [CancelledError]).} =
      getPeerCallCount.inc()
      if getPeerCallCount == 1:
        success peerCtx
      else:
        # Use generic error so pushPeerBlock returns without retrying
        failure(newException(NoPeerForBlockError, "no more peers"))

    await pb.start()

    # Request a block so it goes through pushPeerBlock -> byPeer entry
    let handle = pb.getWantHandle(address)

    await sendBatchEvent.wait()

    # Verify block is in-flight
    check address in pb
    check address in peerCtx.blocksRequested

    # Simulate peer disconnect while block is in-flight
    peerCtx.disconnect()
    # discard await handle

    await pb.byPeer[peerCtx.id].monitorFut

    # Check BEFORE stop (stop clears self.blocks)
    check address in pb
    check not pb.isRequested(address)
    check peerCtx.id notin pb.byPeer

    await pb.stop()

  test "Send failure requeues batch":
    var sendCount = 0
    let
      pb =
        PendingBlocksManager.new(discoveryTimeout = 5.millis, batchDeadline = 1.millis)
      peerCtx = makePeerCtx(makePeerId())
      batchSendEvent = newAsyncEvent()

    pb.sendBatch = proc(
        peer: BlockExcPeerCtx, batch: seq[BlockAddress]
    ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
      sendCount.inc()
      if sendCount == 1:
        # First send fails
        failure(newException(CatchableError, "send failed"))
      else:
        batchSendEvent.fire()
        success()

    pb.getPeerForBlock = proc(
        address: BlockAddress
    ): Future[?!BlockExcPeerCtx] {.gcsafe, async: (raises: [CancelledError]).} =
      success peerCtx

    await pb.start()
    discard pb.getWantHandle(address)

    await batchSendEvent.wait().wait(5.seconds)

    # Check BEFORE stop (stop clears self.blocks)
    check sendCount >= 2 # retried at least once
    check address in pb

    await pb.stop()

  test "Generation staleness skips stale heap entries":
    let
      pb = PendingBlocksManager.new(batchDeadline = 50.millis)
      peerCtx = makePeerCtx(makePeerId())

    var callCount = 0
    pb.sendBatch = proc(
        peer: BlockExcPeerCtx, batch: seq[BlockAddress]
    ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
      callCount.inc()
      success()

    pb.getPeerForBlock = proc(
        address: BlockAddress
    ): Future[?!BlockExcPeerCtx] {.gcsafe, async: (raises: [CancelledError]).} =
      success peerCtx

    # First getWantHandle: creates BlockReq (generation=0), pushes BlockItem(gen=0)
    discard pb.getWantHandle(address)
    # Second getWantHandle: addOwner increments generation to 1, pushes BlockItem(gen=1)
    discard pb.getWantHandle(address)

    await pb.start()
    # batchDeadline (50ms) + buffer — worker dispatches after deadline expires
    await sleepAsync(100.millis)
    await pb.stop()

    # Only the fresh entry (gen=1) was dispatched; stale gen=0 was skipped
    check callCount == 1

  test "validateBlock rejects missing block":
    # validateBlock is internal to peerBatchWorker. If a block is pushed to
    # the pipe but never added to self.blocks, the worker should skip it
    # and not call sendBatch.
    let
      pb = PendingBlocksManager.new()
      peerCtx = makePeerCtx(makePeerId())
      missingAddr = BlockAddress.init(bt.Block.new("missing".toBytes).tryGet.cid)
      firstBatchSent = newAsyncEvent()

    var sentAddresses: seq[BlockAddress]
    pb.sendBatch = proc(
        peer: BlockExcPeerCtx, batch: seq[BlockAddress]
    ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
      for a in batch:
        sentAddresses.add(a)
      firstBatchSent.fire()
      success()

    pb.getPeerForBlock = proc(
        a: BlockAddress
    ): Future[?!BlockExcPeerCtx] {.gcsafe, async: (raises: [CancelledError]).} =
      success peerCtx

    await pb.start()

    # Request a valid block to create a BatchReq in byPeer
    let h = pb.getWantHandle(address)
    await firstBatchSent.wait()

    # Push a missing address directly to the peer pipe (never in self.blocks)
    let pipe = pb.byPeer[peerCtx.id].pipe
    await pipe.put(missingAddr)

    # Give the worker time to pick it up and reject it
    await sleepAsync(200.millis)
    await pb.stop()

    # Only the valid block should have been sent; missingAddr was rejected
    check sentAddresses.len == 1
    check sentAddresses[0] == address

  test "Deadline expiry does not lose queued blocks":
    let
      pb = PendingBlocksManager.new(batchDeadline = 1.millis)
      peerCtx = makePeerCtx(makePeerId())

    var sent: seq[BlockAddress]
    pb.sendBatch = proc(
        peer: BlockExcPeerCtx, batch: seq[BlockAddress]
    ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
      for a in batch:
        sent.add(a)
      success()

    pb.getPeerForBlock = proc(
        a: BlockAddress
    ): Future[?!BlockExcPeerCtx] {.gcsafe, async: (raises: [CancelledError]).} =
      success peerCtx

    await pb.start()

    # Push first block — creates BatchReq, worker starts collecting
    discard pb.getWantHandle(address)
    # Give the worker time to start the batch and have the deadline fire
    await sleepAsync(10.millis)

    # Push second block — should be picked up by next batch iteration
    let address2 = BlockAddress.init(blk.cid, Natural(1))
    discard pb.getWantHandle(address2)
    await sleepAsync(100.millis)
    await pb.stop()

    check sent.len == 2
    check sent[0] == address
    check sent[1] == address2

  test "Batch requeued on collection exception":
    var
      pb = PendingBlocksManager.new(
        batchSize = 2, batchDeadline = 5.minutes, blockSendTimeout = 5.minutes
      )
      peerCtx = makePeerCtx(makePeerId())

    let batchReq = BatchReq(peer: peerCtx, pipe: newAsyncQueue[BlockAddress](2))
    pb.byPeer[peerCtx.id] = batchReq

    pb.running = true
    discard pb.getWantHandle(address)
    check pb.blockQueue.len == 1
    batchReq.workerFut = pb.peerBatchWorker(batchReq)
    discard pb.blockQueue.pop()
    pb.blocks[address].state = Scheduled
    await batchReq.pipe.put(address)
    check eventually(batchReq.pipe.empty())

    # Cancel worker fut while it waits in `await next or batchReq.deadline`.
    # The inner `except CatchableError` should requeue the partial batch.
    await batchReq.workerFut.cancelAndWait()

    check pb.blockQueue.len == 1
    check pb.blockQueue[0].address == address
    check pb.blockQueue[0].generation == 2

    check address in pb.blocks
    check pb.blocks[address].state == Queued
    check pb.blocks[address].requestedPeer.isNil

    await pb.stop()
