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
  ## Cooldown before a block can be re-served to the same peer.
  ## 3x the block request timeout - long enough to prevent amplification,
  ## short enough to allow genuine retries after a failed delivery.
  DefaultWantBlockResendTimeout* = 3 * DefaultRequestTimeout

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
    blocksSent: Table[BlockAddress, Moment] # blocks sent to the peer, with send time
    blocksRequested*: HashSet[BlockAddress] # blocks already requested from the peer
    taskEnqueuedAt*: Moment # set when peer is pushed onto serve task queue

    ## wants exchange
    alreadySent*: HashSet[BlockAddress] # wants already sent in the current window
    state*: WantListState # current circuit state
    windowOpenTime: Moment # when the current window opened
    lastSendTime: Moment # last time a send decision was made
    resendInterval: Duration # 10s — large window
    deltaInterval: Duration # 2s — minimum time between delta sends

    scores*: Table[Cid, PeerScore] # scores per dataset (cid)
    disconnected: Future[void] # completed when peer is removed from store
    lastQueriedAt: Moment # when this peer was last asked about wanted blocks

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
  self.blocksSent.contains(address)

proc markBlockAsSent*(self: BlockExcPeerCtx, address: BlockAddress) =
  self.blocksSent[address] = Moment.now()

proc markBlockAsNotSent*(self: BlockExcPeerCtx, address: BlockAddress) =
  ## Unconditionally clear the sent marker. Used by the cancel path -
  ## a cancelled send never left the peer, so no cooldown applies.
  self.blocksSent.del(address)

proc markQueried*(self: BlockExcPeerCtx, now = Moment.now()) =
  self.lastQueriedAt = now

proc queryQuarantineLeft*(
    self: BlockExcPeerCtx,
    quarantine: Duration = DefaultWantHaveResendTimeout,
    now = Moment.now(),
): ?Duration =
  let left = (self.lastQueriedAt + quarantine) - now
  if left.nanoseconds > 0: left.some else: Duration.none

proc clearSentIfStale*(
    self: BlockExcPeerCtx, address: BlockAddress, cooldown: Duration
): bool =
  ## Gated clear for re-want: clear the sent marker only if the cooldown
  ## has elapsed since the block was last sent to this peer. Returns true
  ## if the marker was cleared (or was never set).
  self.blocksSent.withValue(address, sentAt):
    if (Moment.now() - sentAt[]) >= cooldown:
      self.blocksSent.del(address)
      return true
    return false
  do:
    return true

proc pruneSentBlocks*(
    self: BlockExcPeerCtx,
    wantedSet: HashSet[BlockAddress],
    deliveredAddresses: HashSet[BlockAddress],
) =
  ## Drop sent markers for wanted-but-undelivered blocks (retried next pass).
  ## The resend cooldown is preserved because gated re-wants are never added
  ## to wantedBlocks, so their markers land in the not-wanted bucket and survive.
  var pruned = initTable[BlockAddress, Moment]()
  for address, sentAt in self.blocksSent:
    if address notin wantedSet or address in deliveredAddresses:
      pruned[address] = sentAt
  self.blocksSent = pruned

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
  if peer.scores.len == 0:
    # No evidence yet - baseline like the per-cid score path does, so a
    # freshly discovered peer is not ranked below every known peer.
    return ColdStartScore

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

func cleanPresence*(self: BlockExcPeerCtx, addresses: seq[BlockAddress]) =
  for a in addresses:
    self.blocks.del(a)

func cleanPresence*(self: BlockExcPeerCtx, address: BlockAddress) =
  self.cleanPresence(@[address])

proc blockRequestScheduled*(self: BlockExcPeerCtx, address: BlockAddress) =
  self.blocksRequested.incl(address)

proc blockRequestCleared*(self: BlockExcPeerCtx, address: BlockAddress) =
  self.blocksRequested.excl(address)

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
