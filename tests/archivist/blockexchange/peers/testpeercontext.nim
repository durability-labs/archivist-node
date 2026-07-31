import std/sequtils
import std/sets
import std/importutils

import pkg/chronos
import pkg/libp2p/cid
import ../../examples
import pkg/archivist/blockexchange/peers/peercontext
import ../../../asynctest
import pkg/archivist/blockexchange/protobuf/presence
import pkg/archivist/blocktype

privateAccess(BlockExcPeerCtx)

proc toWantSet(addrs: varargs[BlockAddress]): HashSet[BlockAddress] =
  toHashSet(addrs.toSeq)

proc makeAddr(treeCid: Cid, index: Natural): BlockAddress =
  BlockAddress.init(treeCid, index)

suite "BlockExcPeerCtx want-have circuit":
  test "circuit starts in closed state with empty alreadySent":
    var peer = BlockExcPeerCtx.example
    check peer.state == WantListState.Closed
    check peer.alreadySent.len == 0

  test "decideSend with empty wantList returns none without opening window":
    var peer = BlockExcPeerCtx.example
    let decision = peer.decideSend(initHashSet[BlockAddress]())
    check decision.kind == SendKind.None
    check decision.wakeAfter.isNone
    check peer.state == WantListState.Closed

  test "decideSend from closed returns full and transitions to send-delta":
    var peer = BlockExcPeerCtx.example
    let baseTime = Moment.now()
    let treeCid = Cid.example
    let addrA = makeAddr(treeCid, 0)
    let decision = peer.decideSend(toWantSet(addrA), baseTime)
    check decision.kind == SendKind.Full
    check decision.wants == toWantSet(addrA)
    check decision.wakeAfter.isNone
    check peer.state == WantListState.SendDelta
    check peer.alreadySent == toWantSet(addrA)

  test "decideSend from send-all returns full":
    var peer = BlockExcPeerCtx.example
    let baseTime = Moment.now()
    peer.state = WantListState.SendAll
    peer.windowOpenTime = baseTime
    let treeCid = Cid.example
    let addrA = makeAddr(treeCid, 0)
    let addrB = makeAddr(treeCid, 1)
    let decision = peer.decideSend(toWantSet(addrA, addrB), baseTime)
    check decision.kind == SendKind.Full
    check decision.wants == toWantSet(addrA, addrB)
    check decision.wakeAfter.isNone
    check peer.state == WantListState.SendDelta
    check peer.alreadySent == toWantSet(addrA, addrB)

  test "decideSend from send-delta returns delta of new blocks only":
    var peer = BlockExcPeerCtx.example
    let baseTime = Moment.now()
    peer.state = WantListState.SendDelta
    peer.windowOpenTime = baseTime
    let treeCid = Cid.example
    let addrA = makeAddr(treeCid, 0)
    let addrB = makeAddr(treeCid, 1)
    peer.alreadySent = toWantSet(addrA)
    let decision = peer.decideSend(toWantSet(addrA, addrB), baseTime)
    check decision.kind == SendKind.Delta
    check decision.wants == toWantSet(addrB)
    check decision.wakeAfter.isNone
    check peer.state == WantListState.Wait
    check peer.alreadySent == toWantSet(addrA, addrB)

  test "decideSend from send-delta with empty delta returns none and transitions to wait":
    var peer = BlockExcPeerCtx.example
    let baseTime = Moment.now()
    peer.state = WantListState.SendDelta
    peer.windowOpenTime = baseTime
    let treeCid = Cid.example
    let addrA = makeAddr(treeCid, 0)
    peer.alreadySent = toWantSet(addrA)
    let decision = peer.decideSend(toWantSet(addrA), baseTime)
    check decision.kind == SendKind.None
    check decision.wakeAfter.isSome
    check decision.wakeAfter.unsafeGet() ==
      peer.windowOpenTime + peer.resendInterval - baseTime
    check peer.state == WantListState.Wait

  test "decideSend from send-delta with expired window closes and reopens":
    var peer = BlockExcPeerCtx.example
    let baseTime = Moment.now()
    peer.state = WantListState.SendDelta
    peer.windowOpenTime = baseTime - 11.seconds
    let treeCid = Cid.example
    let addrA = makeAddr(treeCid, 0)
    let addrB = makeAddr(treeCid, 1)
    let addrC = makeAddr(treeCid, 2)
    peer.alreadySent = toWantSet(addrA, addrB)
    let decision = peer.decideSend(toWantSet(addrA, addrB, addrC), baseTime)
    check decision.kind == SendKind.Full
    check decision.wants == toWantSet(addrA, addrB, addrC)
    check decision.wakeAfter.isNone
    check peer.state == WantListState.SendDelta
    check peer.alreadySent == toWantSet(addrA, addrB, addrC)

  test "decideSend from wait with delta interval not elapsed returns none":
    var peer = BlockExcPeerCtx.example
    let baseTime = Moment.now()
    peer.state = WantListState.Wait
    peer.windowOpenTime = baseTime
    peer.lastSendTime = baseTime
    let treeCid = Cid.example
    let addrA = makeAddr(treeCid, 0)
    let addrB = makeAddr(treeCid, 1)
    peer.alreadySent = toWantSet(addrA)
    let decision = peer.decideSend(toWantSet(addrA, addrB), baseTime)
    check decision.kind == SendKind.None
    check decision.wakeAfter.isSome
    check decision.wakeAfter.unsafeGet() ==
      peer.lastSendTime + peer.deltaInterval - baseTime
    check peer.state == WantListState.Wait

  test "decideSend from wait with delta interval elapsed sends delta":
    var peer = BlockExcPeerCtx.example
    let baseTime = Moment.now()
    peer.state = WantListState.Wait
    peer.windowOpenTime = baseTime
    peer.lastSendTime = baseTime - 3.seconds
    let treeCid = Cid.example
    let addrA = makeAddr(treeCid, 0)
    let addrB = makeAddr(treeCid, 1)
    peer.alreadySent = toWantSet(addrA)
    let decision = peer.decideSend(toWantSet(addrA, addrB), baseTime)
    check decision.kind == SendKind.Delta
    check decision.wants == toWantSet(addrB)
    check decision.wakeAfter.isNone
    check peer.state == WantListState.Wait

  test "decideSend from wait with expired window closes and reopens":
    var peer = BlockExcPeerCtx.example
    let baseTime = Moment.now()
    peer.state = WantListState.Wait
    peer.windowOpenTime = baseTime - 11.seconds
    let treeCid = Cid.example
    let addrA = makeAddr(treeCid, 0)
    let addrB = makeAddr(treeCid, 1)
    let addrC = makeAddr(treeCid, 2)
    peer.alreadySent = toWantSet(addrA, addrB)
    let decision = peer.decideSend(toWantSet(addrA, addrB, addrC), baseTime)
    check decision.kind == SendKind.Full
    check decision.wants == toWantSet(addrA, addrB, addrC)
    check decision.wakeAfter.isNone
    check peer.state == WantListState.SendDelta
    check peer.alreadySent == toWantSet(addrA, addrB, addrC)

  test "setPresence does not change circuit state or alreadySent":
    var peer = BlockExcPeerCtx.example
    peer.state = WantListState.SendDelta
    peer.windowOpenTime = Moment.now()
    let treeCid = Cid.example
    let addrA = makeAddr(treeCid, 0)
    peer.alreadySent = toWantSet(addrA)
    let pres = Presence(address: addrA, have: true)
    peer.setPresence(pres)
    check peer.state == WantListState.SendDelta
    check peer.alreadySent == toWantSet(addrA)

  test "closeWindow clears alreadySent and sets state to closed":
    var peer = BlockExcPeerCtx.example
    let treeCid = Cid.example
    let addrA = makeAddr(treeCid, 0)
    peer.alreadySent = toWantSet(addrA)
    peer.state = WantListState.Wait
    peer.closeWindow()
    check peer.state == WantListState.Closed
    check peer.alreadySent.len == 0

  test "decideSend from wait at exact resend-window boundary returns full":
    var peer = BlockExcPeerCtx.example
    let baseTime = Moment.now()
    let treeCid = Cid.example
    let addrA = makeAddr(treeCid, 0)

    # First send from Closed -> Full, transitions to SendDelta
    let decision1 = peer.decideSend(toWantSet(addrA), baseTime)
    check decision1.kind == SendKind.Full
    check peer.state == WantListState.SendDelta

    # Second call at same time: empty delta -> None, transitions to Wait
    let decision2 = peer.decideSend(toWantSet(addrA), baseTime)
    check decision2.kind == SendKind.None
    check peer.state == WantListState.Wait

    # Set lastSendTime to the boundary so the delta interval check does
    # not fire, isolating the resend-window boundary check.
    let boundaryTime = peer.windowOpenTime + peer.resendInterval
    peer.lastSendTime = boundaryTime

    # At the exact boundary (windowOpenTime + resendInterval), the
    # inclusive (<=) check expires the window and returns Full.
    let decision3 = peer.decideSend(toWantSet(addrA), boundaryTime)
    check decision3.kind == SendKind.Full
    check peer.state == WantListState.SendDelta

  test "clearSentIfStale within cooldown keeps marker":
    var peer = BlockExcPeerCtx.example
    let blkAddr = makeAddr(Cid.example, 0)
    peer.markBlockAsSent(blkAddr)
    check peer.isBlockSent(blkAddr)
    let cleared = peer.clearSentIfStale(blkAddr, 90.seconds)
    check not cleared
    check peer.isBlockSent(blkAddr)

  test "clearSentIfStale after cooldown clears marker":
    var peer = BlockExcPeerCtx.example
    let blkAddr = makeAddr(Cid.example, 0)
    peer.markBlockAsSent(blkAddr)
    check peer.isBlockSent(blkAddr)
    let cleared = peer.clearSentIfStale(blkAddr, 0.seconds)
    check cleared
    check not peer.isBlockSent(blkAddr)

  test "clearSentIfStale on never-sent block returns true":
    var peer = BlockExcPeerCtx.example
    let blkAddr = makeAddr(Cid.example, 0)
    let cleared = peer.clearSentIfStale(blkAddr, 90.seconds)
    check cleared
    check not peer.isBlockSent(blkAddr)
