import pkg/chronos

import pkg/archivist/rng
import pkg/archivist/blockexchange

import ../../../asynctest
import ../../helpers
import ../../examples

suite "scoredPeer selector":
  let testCid = Cid.example
  let address = BlockAddress(leaf: false, cid: testCid)

  proc makeCtx(): BlockExcPeerCtx =
    let seckey = PrivateKey.random(Rng.instance[]).tryGet()
    let id = PeerId.init(seckey.getPublicKey().tryGet()).tryGet()
    BlockExcPeerCtx.new(id)

  proc makeCtxWithScore(): BlockExcPeerCtx =
    let ctx = makeCtx()
    discard ctx.ensureScoreFor(testCid)
    ctx

  test "Should return nil when no candidates":
    check scoredPeer(@[], address).isNil

  test "Should return the only candidate when exactly one":
    let ctx = makeCtx()
    check scoredPeer(@[ctx], address) == ctx

  test "Should prefer high-score peer over low-score peer":
    let good = makeCtxWithScore()
    good.ensureScoreFor(testCid).recordDelivery(1024, 10.0)
    good.ensureScoreFor(testCid).recordDelivery(1024, 10.0)
    good.ensureScoreFor(testCid).recordDelivery(1024, 10.0)

    let bad = makeCtxWithScore()
    bad.ensureScoreFor(testCid).recordFailure()
    bad.ensureScoreFor(testCid).recordFailure()
    bad.ensureScoreFor(testCid).recordFailure()

    # With ~5% exploration, the result is not strictly deterministic,
    # but good is overwhelmingly more likely. Run many trials.
    var goodHits: int
    for _ in 0 ..< 100:
      if scoredPeer(@[good, bad], address) == good:
        inc goodHits

    check goodHits > 80

  test "Should exclude circuit-open peers":
    let open = makeCtxWithScore()
    open.ensureScoreFor(testCid).circuitOpen = true
    open.ensureScoreFor(testCid).circuitOpenUntil = Moment.now() + 60.seconds

    let closed = makeCtx()
    check scoredPeer(@[open, closed], address) == closed

  test "Should return nil when all candidates are circuit-open":
    let a = makeCtxWithScore()
    a.ensureScoreFor(testCid).circuitOpen = true
    a.ensureScoreFor(testCid).circuitOpenUntil = Moment.now() + 60.seconds

    let b = makeCtxWithScore()
    b.ensureScoreFor(testCid).circuitOpen = true
    b.ensureScoreFor(testCid).circuitOpenUntil = Moment.now() + 60.seconds
    check scoredPeer(@[a, b], address).isNil

  test "Should floor decayed score at ColdStartScore":
    # A peer with rawScore above ColdStartScore but elapsed way past
    # grace should be floored at ColdStartScore, not zero.
    let stale = makeCtxWithScore()
    # Give it a strong base score.
    stale.ensureScoreFor(testCid).recordDelivery(1024, 10.0)
    stale.ensureScoreFor(testCid).recordDelivery(1024, 10.0)
    stale.ensureScoreFor(testCid).recordDelivery(1024, 10.0)

    # Way past grace and many tau.
    stale.ensureScoreFor(testCid).lastUpdated = Moment.now() - 1.hours
    let
      s = stale.ensureScoreFor(testCid)
      decayed = applyDecay(s.score, s.lastUpdated, 0, Moment.now())
    check decayed == ColdStartScore
    check decayed > 0.0

  test "Should cold-start peers with presence but no score":
    # A peer with block presence but no score entry should still be
    # selectable at ColdStartScore.
    let peer = makeCtx() # no score created
    # setPresence creates the score, but if it was missed, the ranker
    # should still include the peer at ColdStartScore
    let ranked = rankPeersByScore(@[peer], testCid)
    check ranked.len == 1
    check ranked[0] == peer
