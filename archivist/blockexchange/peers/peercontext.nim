## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils
import std/tables
import std/sets

import pkg/libp2p
import pkg/chronos
import pkg/questionable

import ../protobuf/blockexc
import ../protobuf/presence

import ../../blocktype
import ../../logutils

import ./peerscore

logScope:
  topics = "archivist peercontext"

const
  DefaultWantHaveResendTimeout* = 10.seconds
  DefaultWantHaveDeltaInterval* = 50.millis
  DefaultMaxWantListBatchSize* = 1024

type
  WantListState* {.pure.} = enum
    Closed
    SendAll
    SendDelta
    Wait

  SendKind* {.pure.} = enum
    None
    Full
    Delta

  SendDecision* = object
    kind*: SendKind
    wants*: HashSet[BlockAddress]
    wakeAfter*: ?Duration

  BlockExcPeerCtx* = ref object of RootObj
    id*: PeerId

    ## remote peer view
    blocks*: Table[BlockAddress, Presence] # remote peer presence map
    wantedBlocks*: HashSet[BlockAddress] # blocks that the peer wants
    blocksSent*: HashSet[BlockAddress] # blocks already sent to the peer
    blocksRequested*: HashSet[BlockAddress] # blocks already requested from the peer

    ## wants exchange
    alreadySent*: HashSet[BlockAddress] # wants already sent in the current window
    state*: WantListState # current circuit state
    windowOpenTime: Moment # when the current window opened
    lastSendTime: Moment # last time a send decision was made
    resendInterval: Duration # 10s — large window
    deltaInterval: Duration # 2s — minimum time between delta sends

    scores*: Table[Cid, PeerScore] # scores per dataset (cid)
    disconnected: Future[void] # completed when peer is removed from store

proc openWindow*(self: BlockExcPeerCtx, now = Moment.now()) =
  self.state = WantListState.SendAll
  self.windowOpenTime = now

proc closeWindow*(self: BlockExcPeerCtx) =
  self.state = WantListState.Closed
  self.alreadySent.clear()

proc decideSend*(
    self: BlockExcPeerCtx, wantList: HashSet[BlockAddress], now = Moment.now()
): SendDecision =
  ## Core circuit decision. Transitions state and returns what to send.
  ## `wakeAfter` is set on suppressed paths to hint when to retry.
  ## For empty wantList, returns None with no wake hint.

  if wantList.len == 0:
    return SendDecision(kind: SendKind.None, wakeAfter: Duration.none)

  case self.state
  of WantListState.Closed:
    self.openWindow(now)
    self.alreadySent = wantList
    self.lastSendTime = now
    self.state = WantListState.SendDelta
    return SendDecision(kind: SendKind.Full, wants: wantList, wakeAfter: Duration.none)
  of WantListState.SendAll:
    # Defensive: should not be reached (Closed → SendDelta in one call)
    self.alreadySent = wantList
    self.lastSendTime = now
    self.state = WantListState.SendDelta
    return SendDecision(kind: SendKind.Full, wants: wantList, wakeAfter: Duration.none)
  of WantListState.SendDelta:
    # Check window expiry first
    if self.windowOpenTime + self.resendInterval <= now:
      self.closeWindow()
      return self.decideSend(wantList, now)
    # Compute delta
    let delta = wantList - self.alreadySent
    if delta.len == 0:
      self.state = WantListState.Wait
      return SendDecision(
        kind: SendKind.None,
        wakeAfter: (self.windowOpenTime + self.resendInterval - now).some,
      )

    self.alreadySent = self.alreadySent + delta
    self.lastSendTime = now
    self.state = WantListState.Wait
    return SendDecision(kind: SendKind.Delta, wants: delta, wakeAfter: Duration.none)
  of WantListState.Wait:
    # Check window expiry
    if self.windowOpenTime + self.resendInterval <= now:
      self.closeWindow()
      return self.decideSend(wantList, now)

    # Check delta interval elapsed
    if self.lastSendTime + self.deltaInterval < now:
      self.state = WantListState.SendDelta
      return self.decideSend(wantList, now)
    # Not ready
    return SendDecision(
      kind: SendKind.None,
      wakeAfter: (self.lastSendTime + self.deltaInterval - now).some,
    )

proc isBlockSent*(self: BlockExcPeerCtx, address: BlockAddress): bool =
  address in self.blocksSent

proc markBlockAsSent*(self: BlockExcPeerCtx, address: BlockAddress) =
  self.blocksSent.incl(address)

proc markBlockAsNotSent*(self: BlockExcPeerCtx, address: BlockAddress) =
  self.blocksSent.excl(address)

proc peerHave*(self: BlockExcPeerCtx): HashSet[BlockAddress] =
  toHashSet(self.blocks.keys.toSeq)

proc peerHaveCids*(self: BlockExcPeerCtx): HashSet[Cid] =
  self.blocks.keys.toSeq.mapIt(it.cidOrTreeCid).toHashSet

proc peerWantsCids*(self: BlockExcPeerCtx): HashSet[Cid] =
  self.wantedBlocks.toSeq.mapIt(it.cidOrTreeCid).toHashSet

proc contains*(self: BlockExcPeerCtx, address: BlockAddress): bool =
  address in self.blocks

func scoreFor*(self: BlockExcPeerCtx, cid: Cid): ?PeerScore =
  self.scores .? [cid]

proc ensureScoreFor*(self: BlockExcPeerCtx, cid: Cid): PeerScore =
  if score =? self.scores .? [cid]:
    return score

  let peerScore = PeerScore(lastUpdated: Moment.now())
  self.scores[cid] = peerScore
  peerScore

proc aggregateScore*(peer: BlockExcPeerCtx): float =
  var total = 0.0
  for _, score in peer.scores:
    score.computeScore(peer.blocksRequested.len)
    total += float(score.totalDeliveries) * score.score

  total

proc effectiveScore*(peer: BlockExcPeerCtx, cid: Cid, now: Moment): float =
  without score =? peer.scoreFor(cid):
    return ColdStartScore
  score.computeScore(peer.blocksRequested.len)
  applyDecay(score.score, score.lastUpdated, peer.blocksRequested.len, now)

proc setPresence*(self: BlockExcPeerCtx, presence: Presence) =
  if not presence.have:
    self.blocks.del(presence.address)
    return

  if presence.address notin self.blocks:
    let cid = presence.address.cidOrTreeCid
    if cid notin self.scores:
      self.scores[cid] = PeerScore(lastUpdated: Moment.now())

  self.blocks[presence.address] = presence

proc effectiveScore*(peer: BlockExcPeerCtx, cid: Cid, now: Moment): float =
  without score =? peer.scoreFor(cid):
    return ColdStartScore
  score.computeScore(peer.blocksRequested.len)
  applyDecay(score.score, score.lastUpdated, peer.blocksRequested.len, now)

func cleanPresence*(self: BlockExcPeerCtx, addresses: seq[BlockAddress]) =
  for a in addresses:
    self.blocks.del(a)

func cleanPresence*(self: BlockExcPeerCtx, address: BlockAddress) =
  self.cleanPresence(@[address])

proc blockRequestScheduled*(self: BlockExcPeerCtx, address: BlockAddress) =
  self.blocksRequested.incl(address)

proc blockRequestCleared*(self: BlockExcPeerCtx, address: BlockAddress) =
  self.blocksRequested.excl(address)

proc recordDelivery*(
    self: BlockExcPeerCtx, address: BlockAddress, bytes: int, latencyMs: float
) =
  self.ensureScoreFor(address.cidOrTreeCid).recordDelivery(bytes, latencyMs)

proc recordFailure*(self: BlockExcPeerCtx, cid: Cid, isValidation: bool = false) =
  var score = self.ensureScoreFor(cid)
  let wasOpen = score.circuitOpen
  score.recordFailure(isValidation)
  if not wasOpen and score.circuitOpen:
    trace "Peer circuit breaker tripped for dataset",
      peer = self.id, cid, failures = score.consecutiveFailures
    archivist_block_exchange_peer_circuit_open.inc(labelValues = [$self.id])
    archivist_block_exchange_peer_circuit_breaker_trips.inc(labelValues = [$self.id])

proc sendBatchFailure*(self: BlockExcPeerCtx, cid: Cid) =
  var score = self.ensureScoreFor(cid)
  let wasOpen = score.circuitOpen
  score.sendBatchFailure()
  if not wasOpen and score.circuitOpen:
    trace "Peer circuit breaker tripped for dataset (batch)",
      peer = self.id, cid, failures = score.consecutiveFailures
    archivist_block_exchange_peer_circuit_open.inc(labelValues = [$self.id])
    archivist_block_exchange_peer_circuit_breaker_trips.inc(labelValues = [$self.id])

proc isBlockRequested*(self: BlockExcPeerCtx, address: BlockAddress): bool =
  address in self.blocksRequested

proc recordDelivery*(
    self: BlockExcPeerCtx, address: BlockAddress, bytes: int, latencyMs: float
) =
  self.ensureScoreFor(address.cidOrTreeCid).recordDelivery(bytes, latencyMs)

proc recordFailure*(self: BlockExcPeerCtx, cid: Cid, isValidation: bool = false) =
  self.ensureScoreFor(cid).recordFailure(isValidation)

proc sendBatchFailure*(self: BlockExcPeerCtx, cid: Cid) =
  self.ensureScoreFor(cid).sendBatchFailure()

proc disconnect*(self: BlockExcPeerCtx) =
  ## Complete the disconnected future, signaling lifecycle end
  ##

  if not self.disconnected.finished:
    self.disconnected.complete()

func isDisconnected*(self: BlockExcPeerCtx): bool =
  self.disconnected.finished

proc onDisconnect*(
    self: BlockExcPeerCtx
): Future[void] {.async: (raw: true, raises: [CancelledError]).} =
  ## Await this to be notified when the peer is removed from the store
  ##

  self.disconnected.join()

proc new*(
    T: type BlockExcPeerCtx,
    peerId: PeerId,
    wantHaveResendInterval: Duration = DefaultWantHaveResendTimeout,
    wantHaveDeltaInterval: Duration = DefaultWantHaveDeltaInterval,
): BlockExcPeerCtx =
  BlockExcPeerCtx(
    id: peerId,
    disconnected: newFuture[void](),
    resendInterval: wantHaveResendInterval,
    deltaInterval: wantHaveDeltaInterval,
    state: WantListState.Closed,
  )
