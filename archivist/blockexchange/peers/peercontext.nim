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

import ../protobuf/blockexc
import ../protobuf/presence

import ../../blocktype
import ../../logutils

const
  MinRefreshInterval = 1.seconds
  MaxRefreshBackoff = 36
  DefaultMaxWantListBatchSize* = 1024
  DefaultPeerActivityTimeout = 1.minutes

type BlockExcPeerCtx* = ref object of RootObj
  id*: PeerId
  blocks*: Table[BlockAddress, Presence] # remote peer presence map
  wantedBlocks*: HashSet[BlockAddress] # blocks that the peer wants
  exchanged*: int # times peer has exchanged with us
  refreshInProgress*: bool
  lastRefresh*: Moment
  refreshBackoff*: int = 1
  blocksSent*: HashSet[BlockAddress]
  blocksRequested*: HashSet[BlockAddress]
  activityTimeout*: Duration
  lastSentWants*: HashSet[BlockAddress]
  disconnected: Future[void] # completed when peer is removed from store

proc isKnowledgeStale*(self: BlockExcPeerCtx): bool =
  let staleness =
    self.lastRefresh + self.refreshBackoff * MinRefreshInterval < Moment.now()

  if staleness and self.refreshInProgress:
    trace "Cleaning up refresh state", peer = self.id
    self.refreshInProgress = false
    self.refreshBackoff = 1

  staleness

proc isBlockSent*(self: BlockExcPeerCtx, address: BlockAddress): bool =
  address in self.blocksSent

proc markBlockAsSent*(self: BlockExcPeerCtx, address: BlockAddress) =
  self.blocksSent.incl(address)

proc markBlockAsNotSent*(self: BlockExcPeerCtx, address: BlockAddress) =
  self.blocksSent.excl(address)

proc refreshRequested*(self: BlockExcPeerCtx) =
  trace "Refresh requested for peer", peer = self.id, backoff = self.refreshBackoff
  self.refreshInProgress = true
  self.lastRefresh = Moment.now()

proc refreshReplied*(self: BlockExcPeerCtx) =
  self.refreshInProgress = false
  self.lastRefresh = Moment.now()
  self.refreshBackoff = min(self.refreshBackoff * 2, MaxRefreshBackoff)

proc havesUpdated(self: BlockExcPeerCtx) =
  self.refreshBackoff = 1

proc wantsUpdated*(self: BlockExcPeerCtx) =
  self.refreshBackoff = 1

proc peerHave*(self: BlockExcPeerCtx): HashSet[BlockAddress] =
  toHashSet(self.blocks.keys.toSeq)

proc peerHaveCids*(self: BlockExcPeerCtx): HashSet[Cid] =
  self.blocks.keys.toSeq.mapIt(it.cidOrTreeCid).toHashSet

proc peerWantsCids*(self: BlockExcPeerCtx): HashSet[Cid] =
  self.wantedBlocks.toSeq.mapIt(it.cidOrTreeCid).toHashSet

proc contains*(self: BlockExcPeerCtx, address: BlockAddress): bool =
  address in self.blocks

func setPresence*(self: BlockExcPeerCtx, presence: Presence) =
  if not presence.have:
    self.blocks.del(presence.address)
    return

  if presence.address notin self.blocks:
    self.havesUpdated()

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

proc blockRequestAccepted*(self: BlockExcPeerCtx, address: BlockAddress) =
  self.blocksRequested.excl(address)

proc disconnect*(self: BlockExcPeerCtx) =
  ## Complete the disconnected future, signaling lifecycle end
  if not self.disconnected.finished:
    self.disconnected.complete()

proc onDisconnect*(
    self: BlockExcPeerCtx
): Future[void] {.async: (raw: true, raises: [CancelledError]).} =
  ## Await this to be notified when the peer is removed from the store
  self.disconnected.join()

proc new*(
    T: type BlockExcPeerCtx,
    peerId: PeerId,
    activityTimeout = DefaultPeerActivityTimeout,
): BlockExcPeerCtx =
  BlockExcPeerCtx(
    id: peerId, activityTimeout: activityTimeout, disconnected: newFuture[void]()
  )
