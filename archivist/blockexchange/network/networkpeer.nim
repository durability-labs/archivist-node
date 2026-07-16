## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import pkg/chronos
import pkg/libp2p

import ../protobuf/blockexc
import ../protobuf/message
import ../engine/metrics
import ../../errors
import ../../logutils
import ../../utils/trackedfutures

logScope:
  topics = "archivist blockexcnetworkpeer"

type
  ConnProvider* =
    proc(): Future[Connection] {.gcsafe, async: (raises: [CancelledError]).}

  RPCHandler* = proc(peer: NetworkPeer, msg: Message) {.gcsafe, async: (raises: []).}

  NetworkPeer* = ref object of RootObj
    id*: PeerId
    handler*: RPCHandler
    sendConn: Connection
    getConn: ConnProvider
    trackedFutures: TrackedFutures

proc connected*(self: NetworkPeer): bool =
  not (isNil(self.sendConn)) and not (self.sendConn.closed or self.sendConn.atEof)

proc readLoop*(self: NetworkPeer, conn: Connection) {.async: (raises: []).} =
  if isNil(conn):
    trace "No connection to read from", peer = self.id
    return

  trace "Attaching read loop", peer = self.id, connId = conn.oid
  try:
    while not conn.atEof or not conn.closed:
      let data = await conn.readLp(MaxMessageSize.int)

      let decodeStart = Moment.now()
      let msg = Message.protobufDecode(data).mapFailure().tryGet()
      archivist_block_exchange_recv_decode_seconds.observe(
        (Moment.now() - decodeStart).nanoseconds.float64 / 1e9
      )

      trace "Received message", peer = self.id, connId = conn.oid

      let handlerStart = Moment.now()
      await self.handler(self, msg)
      archivist_block_exchange_recv_handler_seconds.observe(
        (Moment.now() - handlerStart).nanoseconds.float64 / 1e9
      )
  except CancelledError:
    trace "Read loop cancelled"
  except CatchableError as err:
    warn "Exception in blockexc read loop", msg = err.msg
  finally:
    trace "Detaching read loop", peer = self.id, connId = conn.oid
    await conn.close()

proc connect*(
    self: NetworkPeer
): Future[Connection] {.async: (raises: [CancelledError]).} =
  if self.connected:
    trace "Already connected", peer = self.id, connId = self.sendConn.oid
    return self.sendConn

  self.sendConn = await self.getConn()
  self.trackedFutures.track(self.readLoop(self.sendConn))
  return self.sendConn

proc send*(
    self: NetworkPeer, msg: Message
) {.async: (raises: [CancelledError, LPStreamError]).} =
  let conn = await self.connect()

  if isNil(conn):
    warn "Unable to get send connection for peer message not sent", peer = self.id
    return

  trace "Sending message", peer = self.id, connId = conn.oid
  let encodeStart = Moment.now()
  let encoded = protobufEncode(msg)
  let encodeNs = (Moment.now() - encodeStart).nanoseconds

  let kind =
    if msg.payload.len > 0:
      "blocks"
    elif msg.blockPresences.len > 0:
      "presence"
    elif msg.wantList.entries.len > 0:
      "wantlist"
    else:
      "other"

  archivist_block_exchange_network_encode_seconds.observe(
    encodeNs.float64 / 1e9, labelValues = [kind]
  )

  let writeStart = Moment.now()
  await conn.writeLp(encoded)
  archivist_block_exchange_network_write_seconds.observe(
    (Moment.now() - writeStart).nanoseconds.float64 / 1e9, labelValues = [kind]
  )

func new*(
    T: type NetworkPeer,
    peer: PeerId,
    connProvider: ConnProvider,
    rpcHandler: RPCHandler,
): NetworkPeer =
  doAssert(not isNil(connProvider), "should supply connection provider")

  NetworkPeer(
    id: peer,
    getConn: connProvider,
    handler: rpcHandler,
    trackedFutures: TrackedFutures(),
  )
