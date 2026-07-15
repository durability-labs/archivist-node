{.push raises: [].}

import std/sequtils
import std/algorithm

import pkg/chronos
import pkg/chronicles
import pkg/libp2p/[cid, peerid]

import ../../blocktype
import ../../rng
import ../peers

logScope:
  topics = "archivist peerscoring"

const DefaultExplorationEpsilon* = 0.05

proc randomPeer*(peers: seq[BlockExcPeerCtx], address: BlockAddress): BlockExcPeerCtx =
  Rng.instance.sample(peers)

proc rankPeersByScore*(peers: seq[BlockExcPeerCtx], cid: Cid): seq[BlockExcPeerCtx] =
  let now = Moment.now()
  var ranked: seq[(float, BlockExcPeerCtx)] = @[]
  for peer in peers:
    without score =? peer.scoreFor(cid):
      ranked.add((ColdStartScore, peer))
      continue

    score.maybeResetCircuit()

    if score.circuitOpen:
      continue

    let s = effectiveScore(peer, cid, now)
    ranked.add((s, peer))

  ranked.sort(
    proc(a, b: auto): int =
      cmp(b[0], a[0])
  )
  ranked.mapIt(it[1])

proc rankPeersByAggregate*(peers: seq[BlockExcPeerCtx]): seq[BlockExcPeerCtx] =
  var ranked = peers.mapIt((aggregateScore(it), it))
  ranked.sort(
    proc(a, b: auto): int =
      cmp(b[0], a[0])
  )
  ranked.mapIt(it[1])

proc scoredPeer*(
    peers: seq[BlockExcPeerCtx], address: BlockAddress
): BlockExcPeerCtx {.gcsafe, raises: [].} =
  let
    cid = address.cidOrTreeCid
    ranked = rankPeersByScore(peers, cid)

  if ranked.len == 0:
    return nil

  if ranked.len == 1:
    return ranked[0]

  if Rng.instance.sampleFloat() < DefaultExplorationEpsilon:
    let picked = Rng.instance.sample(ranked)
    return picked

  let best = ranked[0]

  return best
