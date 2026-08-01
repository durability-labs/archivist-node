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
import pkg/taskpools

import std/isolation
import std/sequtils
import ../../utils/threadspawn

import ../protobuf/blockexc
import ../protobuf/message
import ../engine/metrics
import ../../errors
import ../../logutils
import ../../utils/trackedfutures

logScope:
  topics = "archivist blockexcnetworkpeer"

const OffloadThreshold = 64 * 1024
  # 64 KiB: below this, inline is cheaper than the signal round-trip

type
  ConnProvider* =
    proc(): Future[?!Connection] {.gcsafe, async: (raises: [CancelledError]).}

  RPCHandler* = proc(peer: NetworkPeer, msg: Message) {.gcsafe, async: (raises: []).}

  NetworkPeer* = ref object of RootObj
    id*: PeerId
    handler*: RPCHandler
    sendConn: Connection
    getConn: ConnProvider
    trackedFutures: TrackedFutures
    taskpool*: Taskpool

proc connected*(self: NetworkPeer): bool =
  not (isNil(self.sendConn)) and not (self.sendConn.closed or self.sendConn.atEof)

proc decodeMsgTask(
    ctx: SharedPtr[TaskCtx[Message]], data: seq[byte]
) {.gcsafe, raises: [].} =
  defer:
    discard ctx[].signal.fireSync()
  var r = Message.protobufDecode(data).mapFailure
  ctx[].result = unsafeIsolate(move r)

proc encodeMsgTask(
    ctx: SharedPtr[TaskCtx[seq[byte]]], msg: Message
) {.gcsafe, raises: [].} =
  defer:
    discard ctx[].signal.fireSync()
  var r = success(protobufEncode(msg))
  ctx[].result = unsafeIsolate(move r)

proc readLoop*(self: NetworkPeer, conn: Connection) {.async: (raises: []).} =
  if isNil(conn):
    trace "No connection to read from", peer = self.id
    return

  trace "Attaching read loop", peer = self.id, connId = conn.oid
  try:
    while not conn.atEof or not conn.closed:
      let
        data = await conn.readLp(MaxMessageSize.int)
        decodeStart = Moment.now()
        msg =
          if not self.taskpool.isNil and data.len > OffloadThreshold:
            (
              await spawnJoin[Message](
                proc(ctx: SharedPtr[TaskCtx[Message]]) {.gcsafe, raises: [].} =
                  self.taskpool.spawn decodeMsgTask(ctx, data)
              )
            ).tryGet()
          else:
            Message.protobufDecode(data).mapFailure().tryGet()

      archivist_block_exchange_recv_decode_seconds.observe(
        (Moment.now() - decodeStart).nanoseconds.float64 / 1e9
      )

      trace "Received message", peer = self.id, connId = conn.oid

      let handlerStart = Moment.now()
      await self.handler(self, msg)
      let handlerNs = (Moment.now() - handlerStart).nanoseconds
      archivist_block_exchange_recv_handler_seconds.observe(handlerNs.float64 / 1e9)
      trace "Handler completed",
        peer = self.id, connId = conn.oid, durationMs = handlerNs.float64 / 1e6
  except CancelledError:
    trace "Read loop cancelled"
  except CatchableError as err:
    warn "Exception in blockexc read loop", msg = err.msg
  finally:
    trace "Detaching read loop", peer = self.id, connId = conn.oid
    await conn.close()

proc connect*(
    self: NetworkPeer
): Future[?!Connection] {.async: (raises: [CancelledError]).} =
  if self.connected:
    trace "Already connected", peer = self.id, connId = self.sendConn.oid
    return success self.sendConn

  self.sendConn = ?await self.getConn()
  self.trackedFutures.track(self.readLoop(self.sendConn))
  return success self.sendConn

proc send*(
    self: NetworkPeer, msg: sink Message
): Future[?!void] {.async: (raises: [CancelledError]).} =
  let conn = ?await self.connect()

  if conn.isNil:
    warn "Unable to get send connection for peer message not sent", peer = self.id
    return failure("Unable to get send connection for peer message not sent")

  trace "Sending message", peer = self.id, connId = conn.oid
  # Only offload encode when the payload carries significant block data.
  # Control messages (wantlist/presence/cancel) encode cheaply inline.
  let
    encodeStart = Moment.now()
    encoded =
      if foldl(msg.payload, a + b.blk.data.len, 0) > OffloadThreshold:
        ?await spawnJoin[seq[byte]](
          proc(ctx: SharedPtr[TaskCtx[seq[byte]]]) {.gcsafe, raises: [].} =
            self.taskpool.spawn encodeMsgTask(ctx, msg)
        )
      else:
        protobufEncode(msg)

    encodeNs = (Moment.now() - encodeStart).nanoseconds
    kind = messageKind(msg)

  archivist_block_exchange_network_encode_seconds.observe(
    encodeNs.float64 / 1e9, labelValues = [kind]
  )

  let writeStart = Moment.now()
  trace "WriteLp starting", peer = self.id, connId = conn.oid, bytes = encoded.len, kind
  ?catchAsync(await conn.writeLp(encoded))

  let writeNs = (Moment.now() - writeStart).nanoseconds
  archivist_block_exchange_network_write_seconds.observe(
    writeNs.float64 / 1e9, labelValues = [kind]
  )
  archivist_block_exchange_network_write_bytes.observe(
    encoded.len.float64, labelValues = [kind]
  )

  trace "WriteLp completed",
    peer = self.id,
    connId = conn.oid,
    bytes = encoded.len,
    kind,
    durationMs = writeNs.float64 / 1e6

func new*(
    T: type NetworkPeer,
    peer: PeerId,
    connProvider: ConnProvider,
    rpcHandler: RPCHandler,
    taskpool: Taskpool = nil,
): NetworkPeer =
  doAssert(not isNil(connProvider), "should supply connection provider")

  NetworkPeer(
    id: peer,
    getConn: connProvider,
    handler: rpcHandler,
    trackedFutures: TrackedFutures(),
    taskpool: taskpool,
  )
