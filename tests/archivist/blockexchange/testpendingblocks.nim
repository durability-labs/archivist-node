import std/sequtils
import std/algorithm
import std/heapqueue

import pkg/chronos
import pkg/libp2p
import pkg/stew/byteutils
import pkg/questionable

import pkg/archivist/rng
import pkg/archivist/blocktype as bt
import pkg/archivist/blockexchange
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
    check pendingBlocks.markRequested(address, peerCtx, 1.millis) != nil
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
    check pendingBlocks.markRequested(address, peerCtx, 10.millis) != nil
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
    check pendingBlocks.markRequested(address, peerCtx, 10.millis) != nil
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
    check pendingBlocks.markRequested(address, peerCtx, 10.millis) != nil
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
    check pendingBlocks.markRequested(address, firstPeerCtx, 20.millis) != nil
    await pendingBlocks.clearRequest(address, firstPeerCtx)
    check pendingBlocks.markRequested(address, secondPeerCtx, 1.millis) != nil
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

  test "markRequested sets in-flight and decrements retries":
    let pb = PendingBlocksManager.new()
    discard pb.getWantHandle(address)
    let retriesBefore = pb.retries(address)
    let peerCtx = makePeerCtx(makePeerId())

    discard pb.markRequested(address, peerCtx, 60.seconds)

    check pb.isRequested(address)
    check pb.retries(address) == retriesBefore - 1

  test "clearRequest clears in-flight and removes from blocksRequested":
    let
      peerId = makePeerId()
      peerCtx = makePeerCtx(peerId)
      pb = PendingBlocksManager.new()

    discard pb.getWantHandle(address)
    discard pb.markRequested(address, peerCtx, 60.seconds)
    check pb.isRequested(address)
    check address in peerCtx.blocksRequested

    await pb.clearRequest(address, peerCtx)
    check not pb.isRequested(address)
    check address notin peerCtx.blocksRequested

  test "failWantHandle fails request and removes from blocksRequested":
    let
      peerId = makePeerId()
      peerCtx = makePeerCtx(peerId)
      pb = PendingBlocksManager.new()
      handle = pb.getWantHandle(address)

    discard pb.markRequested(address, peerCtx, 60.seconds)
    check address in peerCtx.blocksRequested

    await pb.failWantHandle(address, StorageFailedEngineError, "test error")
    check handle.finished
    check address notin peerCtx.blocksRequested

  test "resolve completes handle and removes from blocksRequested":
    let
      peerId = makePeerId()
      peerCtx = makePeerCtx(peerId)
      pb = PendingBlocksManager.new()
      handle = pb.getWantHandle(address)

    discard pb.markRequested(address, peerCtx, 60.seconds)
    check address in peerCtx.blocksRequested

    await pb.resolve(address, blk)
    check address notin peerCtx.blocksRequested
    let delivery = await handle
    check delivery.blk == blk
    check delivery.address == address

  test "timeout requeues block and clears peer assignment":
    var timedOut = false
    let
      peerId = makePeerId()
      peerCtx = makePeerCtx(peerId)
      onTimeout = proc(
          timeoutAddress: BlockAddress, timeoutPeer: PeerId
      ) {.gcsafe, async: (raises: [CancelledError]).} =
        check timeoutAddress == address
        check timeoutPeer == peerId
        timedOut = true
      pb = PendingBlocksManager.new(onTimeout = onTimeout)

    discard pb.getWantHandle(address)
    discard pb.markRequested(address, peerCtx, 10.millis)
    check pb.isRequested(address)
    check address in peerCtx.blocksRequested

    check eventually timedOut

    check not pb.isRequested(address)
    check address in pb
    check peerCtx.blocksRequested.len == 0

  test "retryAddresses removes from blocksRequested and requeues":
    let
      peerId = makePeerId()
      peerCtx = makePeerCtx(peerId)
      pb = PendingBlocksManager.new()

    discard pb.getWantHandle(address)
    discard pb.markRequested(address, peerCtx, 60.seconds)
    check address in peerCtx.blocksRequested

    await pb.retryAddresses(@[address], 0.millis)
    check address notin peerCtx.blocksRequested
    check not pb.isRequested(address)
    check address in pb

  test "markRequested with same peer is idempotent":
    let
      peerId = makePeerId()
      peerCtx = makePeerCtx(peerId)
      pb = PendingBlocksManager.new()

    discard pb.getWantHandle(address)
    let retriesBefore = pb.retries(address)

    let result1 = pb.markRequested(address, peerCtx, 60.seconds)
    check result1 == peerCtx
    check pb.retries(address) == retriesBefore - 1

    let result2 = pb.markRequested(address, peerCtx, 60.seconds)
    check result2 == peerCtx
    check pb.retries(address) == retriesBefore - 1

  test "markRequested with different peer returns previous":
    let
      peerId1 = makePeerId()
      peerCtx1 = makePeerCtx(peerId1)
      peerId2 = makePeerId()
      peerCtx2 = makePeerCtx(peerId2)
      pb = PendingBlocksManager.new()

    discard pb.getWantHandle(address)
    let result1 = pb.markRequested(address, peerCtx1, 60.seconds)
    check result1 == peerCtx1

    let result2 = pb.markRequested(address, peerCtx2, 60.seconds)
    check result2 == peerCtx1
    check pb.getRequestPeerCtx(address) == peerCtx1

  test "scheduler respects priority ordering":
    let
      pb = PendingBlocksManager.new(batchSize = 1, batchDeadline = 1.millis)
      lowPriorityAddress = BlockAddress.init(bt.Block.new("low".toBytes).tryGet.cid)
      highPriorityAddress = BlockAddress.init(bt.Block.new("high".toBytes).tryGet.cid)
      bothSent = newFuture[void]()

    var sentAddresses: seq[BlockAddress]

    proc sendBatch(
        peer: BlockExcPeerCtx, batch: seq[BlockAddress]
    ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
      sentAddresses.add(batch[0])
      if sentAddresses.len == 2 and not bothSent.finished:
        bothSent.complete()
      success()

    let peerCtx = makePeerCtx(makePeerId())
    pb.sendBatch = sendBatch
    pb.getPeerForBlock = proc(
        address: BlockAddress
    ): Future[?!BlockExcPeerCtx] {.gcsafe, async: (raises: [CancelledError]).} =
      success peerCtx

    discard pb.start()

    # Add low priority first, then high priority (higher numeric = higher priority in max-heap)
    discard pb.getWantHandle(lowPriorityAddress, priority = 1)
    discard pb.getWantHandle(highPriorityAddress, priority = 10)

    await bothSent.wait(1.seconds)
    await pb.stop()

    check sentAddresses.len == 2
    check sentAddresses[0] == lowPriorityAddress # priority 1 pops first (min-heap)
    check sentAddresses[1] == highPriorityAddress
