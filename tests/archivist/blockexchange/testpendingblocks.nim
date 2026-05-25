import std/sequtils
import std/algorithm

import pkg/chronos
import pkg/libp2p
import pkg/stew/byteutils

import pkg/archivist/rng
import pkg/archivist/blocktype as bt
import pkg/archivist/blockexchange

import ../helpers
import ../../asynctest

proc makePeerId(): PeerId =
  let seckey = PrivateKey.random(Rng.instance()[]).tryGet()
  PeerId.init(seckey.getPublicKey().tryGet()).tryGet()

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
    pendingBlocks.resolve(@[blk].mapIt(BlockDelivery(blk: it, address: it.address)))
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

    pendingBlocks.resolve(@[BlockDelivery(blk: blk, address: blk.address)])
    check (await handle2).blk == blk

  test "Should cancel all want handles":
    let
      pendingBlocks = PendingBlocksManager.new()
      blks = (0 .. 9).mapIt(bt.Block.new(("Hello " & $it).toBytes).tryGet)
      handles = blks.mapIt(pendingBlocks.getWantHandle(it.cid))

    await pendingBlocks.cancelAll()

    check pendingBlocks.len == 0
    for handle in handles:
      expect CancelledError:
        discard await handle

  test "Should fire request timeout for current attempt":
    let
      pendingBlocks = PendingBlocksManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet
      address = BlockAddress.init(blk.cid)
      peer = makePeerId()

    var timedOut = false
    pendingBlocks.onTimeout = proc(
        timeoutAddress: BlockAddress, timeoutPeer: PeerId
    ) {.gcsafe, async: (raises: []).} =
      check timeoutAddress == address
      check timeoutPeer == peer
      timedOut = true

    discard pendingBlocks.getWantHandle(blk.cid)
    check pendingBlocks.markRequested(address, peer, 1.millis).isSome
    check eventually timedOut

  test "Should cancel request timeout on clear":
    let
      pendingBlocks = PendingBlocksManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet
      address = BlockAddress.init(blk.cid)
      peer = makePeerId()

    var timedOut = false
    pendingBlocks.onTimeout = proc(
        timeoutAddress: BlockAddress, timeoutPeer: PeerId
    ) {.gcsafe, async: (raises: []).} =
      timedOut = true

    discard pendingBlocks.getWantHandle(blk.cid)
    check pendingBlocks.markRequested(address, peer, 10.millis).isSome
    await pendingBlocks.clearRequest(address, peer)
    await sleepAsync(50.millis)
    check not timedOut

  test "Should cancel request timeout on resolve":
    let
      pendingBlocks = PendingBlocksManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet
      address = BlockAddress.init(blk.cid)
      peer = makePeerId()

    var timedOut = false
    pendingBlocks.onTimeout = proc(
        timeoutAddress: BlockAddress, timeoutPeer: PeerId
    ) {.gcsafe, async: (raises: []).} =
      timedOut = true

    let handle = pendingBlocks.getWantHandle(blk.cid)
    check pendingBlocks.markRequested(address, peer, 10.millis).isSome
    pendingBlocks.resolve(@[BlockDelivery(blk: blk, address: blk.address)])
    check (await handle).blk == blk
    await sleepAsync(20.millis)
    check not timedOut

  test "Should cancel request timeout on final owner release":
    let
      pendingBlocks = PendingBlocksManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet
      address = BlockAddress.init(blk.cid)
      peer = makePeerId()

    var timedOut = false
    pendingBlocks.onTimeout = proc(
        timeoutAddress: BlockAddress, timeoutPeer: PeerId
    ) {.gcsafe, async: (raises: []).} =
      timedOut = true

    let handle = pendingBlocks.getWantHandle(blk.cid)
    check pendingBlocks.markRequested(address, peer, 10.millis).isSome
    await handle.cancelAndWait()
    check eventually blk.cid notin pendingBlocks
    await sleepAsync(20.millis)
    check not timedOut

  test "Should replace cleared request timeout with next attempt":
    let
      pendingBlocks = PendingBlocksManager.new()
      blk = bt.Block.new("Hello".toBytes).tryGet
      address = BlockAddress.init(blk.cid)
      firstPeer = makePeerId()
      secondPeer = makePeerId()

    var timeouts: seq[PeerId]
    pendingBlocks.onTimeout = proc(
        timeoutAddress: BlockAddress, timeoutPeer: PeerId
    ) {.gcsafe, async: (raises: []).} =
      check timeoutAddress == address
      timeouts.add(timeoutPeer)

    discard pendingBlocks.getWantHandle(blk.cid)
    check pendingBlocks.markRequested(address, firstPeer, 20.millis).isSome
    await pendingBlocks.clearRequest(address, firstPeer)
    check pendingBlocks.markRequested(address, secondPeer, 1.millis).isSome
    check eventually timeouts.len == 1
    check timeouts[0] == secondPeer
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
      pendingBlocks = PendingBlocksManager.new(3)
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
