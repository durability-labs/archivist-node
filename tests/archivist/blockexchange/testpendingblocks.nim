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

  test "markRequested sets in-flight":
    let pb = PendingBlocksManager.new()
    discard pb.getWantHandle(address)
    let retriesBefore = pb.retries(address)
    let peerCtx = makePeerCtx(makePeerId())

    discard pb.markRequested(address, peerCtx, 60.seconds)

    check pb.isRequested(address)
    # markRequested decrements retries internally now
    check pb.retries(address) == retriesBefore - 1

  test "clearRequest clears in-flight":
    let pb = PendingBlocksManager.new()
    discard pb.getWantHandle(address)
    let peerCtx = makePeerCtx(makePeerId())
    discard pb.markRequested(address, peerCtx, 60.seconds)
    check pb.isRequested(address)

    await pb.clearRequest(address, peerCtx)
    check not pb.isRequested(address)

  test "failWantHandle fails request":
    let pb = PendingBlocksManager.new()
    let handle = pb.getWantHandle(address)
    await pb.failWantHandle(address, StorageFailedEngineError, "test error")
    check handle.finished

  test "resolve completes handle":
    let pb = PendingBlocksManager.new()
    let handle = pb.getWantHandle(address)
    let peerCtx = makePeerCtx(makePeerId())
    discard pb.markRequested(address, peerCtx, 60.seconds)
    await pb.resolve(address, blk)
    let delivery = await handle
    check delivery.blk == blk
    check delivery.address == address
