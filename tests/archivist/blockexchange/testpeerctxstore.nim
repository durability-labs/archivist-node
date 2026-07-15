import std/sugar

import pkg/unittest2
import pkg/libp2p

import pkg/archivist/blockexchange/peers
import pkg/archivist/blockexchange/protobuf/presence

import ../helpers
import ../examples

suite "Peer Context Store":
  var
    store: PeerCtxStore
    peerCtx: BlockExcPeerCtx

  setup:
    store = PeerCtxStore.new()
    peerCtx = BlockExcPeerCtx.example
    store.add(peerCtx)

  test "Should add peer":
    check peerCtx.id in store

  test "Should remove peer":
    store.remove(peerCtx.id)
    check peerCtx.id notin store

  test "Should get peer":
    check store.get(peerCtx.id) == peerCtx

  test "Should persist peer score across remove and re-add":
    let peerId = peerCtx.id
    peerCtx.score.recordDelivery(1024, 50.0)
    check peerCtx.score.totalDeliveries == 1
    check peerCtx.score.totalBytes == 1024
    store.remove(peerId)
    let newCtx = BlockExcPeerCtx.new(peerId)
    check newCtx.score.totalDeliveries == 0
    store.add(newCtx)
    check newCtx.score.totalDeliveries == 1
    check newCtx.score.totalBytes == 1024

  test "Should persist stale context's latest score on re-add":
    let peerId = peerCtx.id
    # peerCtx is already in the store (from setup). Modify its score.
    peerCtx.score.recordDelivery(2048, 50.0)
    check peerCtx.score.totalDeliveries == 1
    # Add a different context for the same peerId without removing first.
    # This triggers the existing-context-replacement path: the latest
    # score from the live context must be persisted to LRU before the
    # new context inherits it.
    let newCtx = BlockExcPeerCtx.new(peerId)
    store.add(newCtx)
    check newCtx.score.totalBytes == 2048

suite "Peer Context Store Peer Selection":
  var
    store: PeerCtxStore
    peerCtxs: seq[BlockExcPeerCtx]
    addresses: seq[BlockAddress]

  setup:
    store = PeerCtxStore.new()
    addresses = collect(newSeq):
      for i in 0 ..< 10:
        BlockAddress(leaf: false, cid: Cid.example)

    peerCtxs = collect(newSeq):
      for i in 0 ..< 10:
        BlockExcPeerCtx.example

    for p in peerCtxs:
      store.add(p)

  teardown:
    store = nil
    addresses = @[]
    peerCtxs = @[]

  test "Should select peers that have Cid":
    peerCtxs[0].blocks = collect(initTable):
      for a in addresses:
        {a: Presence(address: a)}

    peerCtxs[5].blocks = collect(initTable):
      for a in addresses:
        {a: Presence(address: a)}

    let peers = store.peersHave(addresses[0])

    check peers.len == 2
    check peerCtxs[0] in peers
    check peerCtxs[5] in peers

  test "Should select peers that want Cid":
    for address in addresses:
      peerCtxs[0].wantedBlocks.incl(address)
      peerCtxs[5].wantedBlocks.incl(address)

    let peers = store.peersWant(addresses[4])

    check peers.len == 2
    check peerCtxs[0] in peers
    check peerCtxs[5] in peers

  test "Should return peers with and without block":
    let address = addresses[2]

    peerCtxs[1].blocks[address] = Presence(address: address)
    peerCtxs[2].blocks[address] = Presence(address: address)

    let peers = store.getPeersForBlock(address)

    for i, pc in peerCtxs:
      if i == 1 or i == 2:
        check pc in peers.with
        check pc notin peers.without
      else:
        check pc notin peers.with
        check pc in peers.without
