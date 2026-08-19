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

const
  DefaultExplorationEpsilon* = 0.05
  ## Among top-scoring peers, prefer least blocksRequested (MESH fan-out).
  DefaultWantBlockTopK* = 3

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

  # Randomize equal-score groups (stable sort preserves shuffle order)
  Rng.instance.shuffle(ranked)
  ranked.sort(
    proc(a, b: auto): int =
      cmp(b[0], a[0])
  )
  ranked.mapIt(it[1])

proc rankPeersByAggregate*(peers: seq[BlockExcPeerCtx]): seq[BlockExcPeerCtx] =
  var ranked = peers.mapIt((aggregateScore(it), it))
  # Randomize equal-score groups (stable sort preserves shuffle order)
  Rng.instance.shuffle(ranked)
  ranked.sort(
    proc(a, b: auto): int =
      cmp(b[0], a[0])
  )
  ranked.mapIt(it[1])

proc scoredPeer*(
    peers: seq[BlockExcPeerCtx], address: BlockAddress
): BlockExcPeerCtx {.gcsafe, raises: [].} =
  ## Rank by score, then among the top-K pick the least loaded peer so
  ## concurrent downloaders fan out instead of pinning the origin.
  let
    cid = address.cidOrTreeCid
    ranked = rankPeersByScore(peers, cid)

  if ranked.len == 0:
    return nil

  if ranked.len == 1:
    return ranked[0]

  if Rng.instance.sampleFloat() < DefaultExplorationEpsilon:
    return Rng.instance.sample(ranked)

  let k = min(DefaultWantBlockTopK, ranked.len)
  var
    best = ranked[0]
    bestLoad = best.blocksRequested.len
  for i in 1 ..< k:
    let load = ranked[i].blocksRequested.len
    if load < bestLoad:
      best = ranked[i]
      bestLoad = load
  best
