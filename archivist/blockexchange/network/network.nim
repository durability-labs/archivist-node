## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/tables
import std/sequtils

import pkg/chronos
import pkg/taskpools

import pkg/libp2p
import pkg/libp2p/utils/semaphore

import ../../blocktype as bt
import ../../logutils
import ../../errors
import ../protobuf/blockexc as pb
import ../../utils/trackedfutures
import ../../errors

import ./networkpeer
import ../engine/metrics

export networkpeer

logScope:
  topics = "archivist blockexcnetwork"

const
  Codec* = "/archivist/blockexc/1.0.0"
  DefaultMaxInflight* = 100

type
  WantListHandler* =
    proc(peer: PeerId, wantList: WantList) {.gcsafe, async: (raises: []).}

  BlocksDeliveryHandler* =
    proc(peer: PeerId, blocks: seq[BlockDelivery]) {.gcsafe, async: (raises: []).}

  BlockPresenceHandler* =
    proc(peer: PeerId, precense: seq[BlockPresence]) {.gcsafe, async: (raises: []).}

  BlockExcHandlers* = object
    onWantList*: WantListHandler
    onBlocksDelivery*: BlocksDeliveryHandler
    onPresence*: BlockPresenceHandler

  WantListSender* = proc(
    id: PeerId,
    addresses: seq[BlockAddress],
    priority: int32 = 0,
    cancel: bool = false,
    wantType: WantType = WantType.WantHave,
    full: bool = false,
    sendDontHave: bool = false,
  ): Future[?!void] {.async: (raises: [CancelledError]).}

  WantCancellationSender* = proc(
    peer: PeerId, addresses: seq[BlockAddress]
  ): Future[?!void] {.async: (raises: [CancelledError]).}

  BlocksDeliverySender* = proc(
    peer: PeerId, blocksDelivery: seq[BlockDelivery]
  ): Future[?!void] {.async: (raises: [CancelledError]).}

  PresenceSender* = proc(peer: PeerId, presence: seq[BlockPresence]): Future[?!void] {.
    async: (raises: [CancelledError])
  .}

  BlockExcRequest* = object
    sendWantList*: WantListSender
    sendWantCancellations*: WantCancellationSender
    sendBlocksDelivery*: BlocksDeliverySender
    sendPresence*: PresenceSender

  BlockExcNetwork* = ref object of LPProtocol
    peers: Table[PeerId, NetworkPeer]
    switch*: Switch
    handlers*: BlockExcHandlers
    request*: BlockExcRequest
    getConn: ConnProvider
    inflightSema: AsyncSemaphore
    inflightSlots: int
    maxInflight = DefaultMaxInflight
    trackedFutures = TrackedFutures()
    taskpool*: Taskpool

proc peerId*(b: BlockExcNetwork): PeerId =
  ## Return peer id
  ##

  b.switch.peerInfo.peerId

proc isSelf*(b: BlockExcNetwork, peer: PeerId): bool =
  ## Check if peer is self
  ##

  b.peerId == peer

proc send*(
    b: BlockExcNetwork, id: PeerId, msg: sink pb.Message
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Send message to peer. Returns success if the message was written to the
  ## transport, failure with the transport error otherwise.
  ##

  let peer = b.peers.getOrDefault(id)
  if peer.isNil:
    trace "Unable to send, peer not found", peerId = id
    return failure(newException(ArchivistError, "peer not found: " & $id))

  let
    kind = messageKind(msg)
    totalStart = Moment.now()

  let inflightWaitStart = Moment.now()
  await b.inflightSema.acquire()
  if b.maxInflight > 0:
    dec b.inflightSlots
  archivist_block_exchange_network_inflight_wait_seconds.observe(
    (Moment.now() - inflightWaitStart).nanoseconds.float64 / 1e9, labelValues = [kind]
  )

  archivist_block_exchange_inflight_sends.set((b.maxInflight - b.inflightSlots).int64)
  archivist_block_exchange_inflight_send_slots_free.set(b.inflightSlots.int64)

  try:
    if err =? catchAsync(await peer.send(msg)).errorOption:
      error "Error sending message", peer = id, msg = err.msg
      return failure(err)
  finally:
    try:
      b.inflightSema.release()
    except AsyncSemaphoreError as error:
      raise newException(AssertionDefect, error.msg, error)
    if b.maxInflight > 0:
      inc b.inflightSlots
    archivist_block_exchange_inflight_sends.set((b.maxInflight - b.inflightSlots).int64)
    archivist_block_exchange_inflight_send_slots_free.set(b.inflightSlots.int64)

  archivist_block_exchange_network_send_seconds.observe(
    (Moment.now() - totalStart).nanoseconds.float64 / 1e9, labelValues = [kind]
  )

  success()

proc handleWantList(
    b: BlockExcNetwork, peer: NetworkPeer, list: WantList
) {.async: (raises: []).} =
  ## Handle incoming want list
  ##

  if not b.handlers.onWantList.isNil:
    await b.handlers.onWantList(peer.id, list)

proc sendWantList*(
    b: BlockExcNetwork,
    id: PeerId,
    addresses: seq[BlockAddress],
    priority: int32 = 0,
    cancel: bool = false,
    wantType: WantType = WantType.WantHave,
    full: bool = false,
    sendDontHave: bool = false,
): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
  ## Send a want message to peer
  ##

  let msg = WantList(
    entries: addresses.mapIt(
      WantListEntry(
        address: it,
        priority: priority,
        cancel: cancel,
        wantType: wantType,
        sendDontHave: sendDontHave,
      )
    ),
    full: full,
  )

  return b.send(id, Message(wantlist: msg))

proc sendWantCancellations*(
    b: BlockExcNetwork, id: PeerId, addresses: seq[BlockAddress]
): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
  ## Informs a remote peer that we're no longer interested in a set of blocks
  ##

  b.sendWantList(id = id, addresses = addresses, cancel = true)

proc handleBlocksDelivery(
    b: BlockExcNetwork, peer: NetworkPeer, blocksDelivery: seq[BlockDelivery]
) {.async: (raises: []).} =
  ## Handle incoming blocks
  ##

  if not b.handlers.onBlocksDelivery.isNil:
    await b.handlers.onBlocksDelivery(peer.id, blocksDelivery)

proc sendBlocksDelivery*(
    b: BlockExcNetwork, id: PeerId, blocksDelivery: seq[BlockDelivery]
): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
  ## Send blocks to remote. Returns success if the batch was written to the
  ## transport, failure with the transport error otherwise.
  ##

  b.send(id, pb.Message(payload: blocksDelivery))

proc handleBlockPresence(
    b: BlockExcNetwork, peer: NetworkPeer, presence: seq[BlockPresence]
) {.async: (raises: []).} =
  ## Handle block presence
  ##

  if not b.handlers.onPresence.isNil:
    await b.handlers.onPresence(peer.id, presence)

proc sendBlockPresence*(
    b: BlockExcNetwork, id: PeerId, presence: seq[BlockPresence]
): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
  ## Send presence to remote
  ##

  b.send(id, Message(blockPresences: @presence))

proc rpcHandler*(
    b: BlockExcNetwork, peer: NetworkPeer, msg: Message
) {.async: (raises: []).} =
  ## handle rpc messages
  ##

  if msg.wantList.entries.len > 0:
    b.trackedFutures.track(b.handleWantList(peer, msg.wantList))

  if msg.payload.len > 0:
    b.trackedFutures.track(b.handleBlocksDelivery(peer, msg.payload))

  if msg.blockPresences.len > 0:
    b.trackedFutures.track(b.handleBlockPresence(peer, msg.blockPresences))

proc getOrCreatePeer(b: BlockExcNetwork, peer: PeerId): NetworkPeer =
  ## Creates or retrieves a BlockExcNetwork Peer
  ##

  if peer in b.peers:
    return b.peers.getOrDefault(peer, nil)

  # create new pubsub peer
  let blockExcPeer = NetworkPeer.new(
    peer,
    proc(): Future[?!Connection] {.async: (raises: [CancelledError]).} =
      trace "Getting new connection stream", peer
      return catchAsync(await b.switch.dial(peer, Codec)),
    proc(p: NetworkPeer, msg: Message) {.async: (raises: []).} =
      await b.rpcHandler(p, msg)
    ,
    b.taskpool,
  )

  debug "Created new blockexc peer", peer

  b.peers[peer] = blockExcPeer

  return blockExcPeer

proc setupPeer*(b: BlockExcNetwork, peer: PeerId) =
  ## Perform initial setup, such as want
  ## list exchange
  ##

  discard b.getOrCreatePeer(peer)

proc dialPeer*(b: BlockExcNetwork, peer: PeerRecord) {.async.} =
  ## Dial a peer
  ##

  if b.isSelf(peer.peerId):
    trace "Skipping dialing self", peer = peer.peerId
    return

  if peer.peerId in b.peers:
    trace "Already connected to peer", peer = peer.peerId
    return

  await b.switch.connect(peer.peerId, peer.addresses.mapIt(it.address))

proc dropPeer*(b: BlockExcNetwork, peer: PeerId) {.async: (raises: []).} =
  ## Cleanup disconnected peer
  ##

  trace "Dropping peer", peer
  if err =? catch(await noCancel b.switch.disconnect(peer)).errorOption:
    trace "Error dropping peer", peer
    return

  b.peers.del(peer)

method init*(self: BlockExcNetwork) =
  ## Perform protocol initialization
  ##

  proc peerEventHandler(
      peerId: PeerId, event: PeerEvent
  ): Future[void] {.gcsafe, async: (raises: [CancelledError]).} =
    if event.kind == PeerEventKind.Joined:
      self.setupPeer(peerId)
    else:
      self.peers.del(peerId)

  self.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Joined)
  self.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Left)

  proc handler(
      conn: Connection, proto: string
  ): Future[void] {.async: (raises: [CancelledError]).} =
    let
      peerId = conn.peerId
      blockexcPeer = self.getOrCreatePeer(peerId)

    await blockexcPeer.readLoop(conn) # attach read loop

  self.handler = handler
  self.codec = Codec

proc stop*(self: BlockExcNetwork) {.async: (raises: []).} =
  await self.trackedFutures.cancelTracked()

proc new*(
    T: type BlockExcNetwork,
    switch: Switch,
    connProvider: ConnProvider = nil,
    maxInflight = DefaultMaxInflight,
    taskpool: Taskpool = nil,
): BlockExcNetwork =
  ## Create a new BlockExcNetwork instance
  ##

  var inflightSema: AsyncSemaphore
  if maxInflight == 0:
    inflightSema = newAsyncSemaphore(1)
    discard inflightSema.tryAcquire()
  else:
    inflightSema = newAsyncSemaphore(maxInflight)

  let self = BlockExcNetwork(
    switch: switch,
    getConn: connProvider,
    inflightSema: inflightSema,
    inflightSlots: (if maxInflight == 0: 0 else: maxInflight),
    maxInflight: maxInflight,
    taskpool: taskpool,
  )

  self.maxIncomingStreams = self.maxInflight

  proc sendWantList(
      id: PeerId,
      cids: seq[BlockAddress],
      priority: int32 = 0,
      cancel: bool = false,
      wantType: WantType = WantType.WantHave,
      full: bool = false,
      sendDontHave: bool = false,
  ): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
    self.sendWantList(id, cids, priority, cancel, wantType, full, sendDontHave)

  proc sendWantCancellations(
      id: PeerId, addresses: seq[BlockAddress]
  ): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
    self.sendWantCancellations(id, addresses)

  proc sendBlocksDelivery(
      id: PeerId, blocksDelivery: seq[BlockDelivery]
  ): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
    self.sendBlocksDelivery(id, blocksDelivery)

  proc sendPresence(
      id: PeerId, presence: seq[BlockPresence]
  ): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
    self.sendBlockPresence(id, presence)

  self.request = BlockExcRequest(
    sendWantList: sendWantList,
    sendWantCancellations: sendWantCancellations,
    sendBlocksDelivery: sendBlocksDelivery,
    sendPresence: sendPresence,
  )

  self.init()
  return self
