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
    testCid: Cid
    testAddress: BlockAddress

  setup:
    store = PeerCtxStore.new()
    peerCtx = BlockExcPeerCtx.example
    testCid = Cid.example
    testAddress = BlockAddress.init(testCid)
    store.add(peerCtx)

  test "Should add peer":
    check peerCtx.id in store

  test "Should remove peer":
    store.remove(peerCtx.id)
    check peerCtx.id notin store

  test "Should get peer":
    check store.get(peerCtx.id) == peerCtx

  test "Should persist per-dataset peer score across remove and re-add":
    let peerId = peerCtx.id
    peerCtx.recordDelivery(testAddress, 1024, 50.0)
    check peerCtx.scoreFor(testCid).isSome

    let score = !peerCtx.scoreFor(testCid)
    check score.totalDeliveries == 1
    check score.totalBytes == 1024
    store.remove(peerId)

    # Fresh context should NOT have the score yet (not restored)
    let newCtx = BlockExcPeerCtx.new(peerId)
    check newCtx.scoreFor(testCid).isNone

    store.add(newCtx)
    # After add(), score should be restored from LRU
    check newCtx.scoreFor(testCid).isSome

    let restored = !newCtx.scoreFor(testCid)
    check restored.totalDeliveries == 1
    check restored.totalBytes == 1024

  test "Should persist stale context's latest per-dataset score on re-add":
    let peerId = peerCtx.id
    peerCtx.recordDelivery(testAddress, 2048, 50.0)
    check peerCtx.scoreFor(testCid).isSome

    let score = peerCtx.scoreFor(testCid).get
    check score.totalDeliveries == 1
    let newCtx = BlockExcPeerCtx.new(peerId)
    store.add(newCtx)
    check newCtx.scoreFor(testCid).isSome

    let restored = newCtx.scoreFor(testCid).get
    check restored.totalBytes == 2048

  test "Should isolate peer feedback by dataset":
    let
      cid1 = testCid
      cid2 = Cid.example
      addr1 = BlockAddress.init(cid1)
      addr2 = BlockAddress.init(cid2)

    # Create two score entries on different datasets
    peerCtx.recordDelivery(addr1, 1024, 50.0)
    peerCtx.recordDelivery(addr2, 2048, 100.0)
    check peerCtx.scoreFor(cid1).isSome
    check peerCtx.scoreFor(cid2).isSome

    let score1 = !peerCtx.scoreFor(cid1)
    let score2 = !peerCtx.scoreFor(cid2)
    check score1.totalDeliveries == 1
    check score2.totalDeliveries == 1
    check score1.totalBytes == 1024
    check score2.totalBytes == 2048

    # Record failure on one CID — the other must be unchanged
    peerCtx.recordFailure(cid1)
    let score1After = !peerCtx.scoreFor(cid1)
    let score2After = !peerCtx.scoreFor(cid2)
    check score1After.totalFailures == 1
    check score2After.totalFailures == 0
    check score2After.totalDeliveries == 1
    check score2After.totalBytes == 2048

    # Remove and re-add the peer context; both entries and their
    # independent counters must be restored
    let peerId = peerCtx.id
    store.remove(peerId)
    let newCtx = BlockExcPeerCtx.new(peerId)
    store.add(newCtx)
    check newCtx.scoreFor(cid1).isSome
    check newCtx.scoreFor(cid2).isSome
    let restored1 = !newCtx.scoreFor(cid1)
    let restored2 = !newCtx.scoreFor(cid2)
    check restored1.totalFailures == 1
    check restored1.totalDeliveries == 1
    check restored2.totalFailures == 0
    check restored2.totalDeliveries == 1
    check restored2.totalBytes == 2048

  test "aggregateScore recomputes stale per-dataset scores":
    # Record enough deliveries to exceed MinSamplesForScore so computeScore
    # produces a real score instead of ColdStartScore
    for i in 0 ..< 5:
      peerCtx.recordDelivery(testAddress, 1024, 50.0)

    # Without calling effectiveScore or any per-CID ranker first,
    # aggregateScore must still reflect the recorded delivery history.
    # The stale bug would return ColdStartScore (0.1) per dataset because
    # score.score was never recomputed after recordDelivery.
    let aggregate = peerCtx.aggregateScore()
    check aggregate > float(peerCtx.scores.len) * ColdStartScore

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
