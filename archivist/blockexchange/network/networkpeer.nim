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
import pkg/results

import std/isolation
import std/sequtils
import pkg/threadspawn

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
    ctx: SharedPtr[TaskCtx[Message]], data: ptr seq[byte]
) {.gcsafe, raises: [].} =
  defer:
    if err =? ctx[].signal.fireSync().errorOption:
      warn "Failed to fire worker completion signal", error = err

  var r = Message.decode(data[]).mapThreadSpawnErr
  ctx[].result = isolate(move r)

proc encodeMsgTask(
    ctx: SharedPtr[TaskCtx[seq[byte]]], msg: ptr Message
) {.gcsafe, raises: [].} =
  defer:
    if err =? ctx[].signal.fireSync().errorOption:
      warn "Failed to fire worker completion signal", error = err

  var r = ThreadSpawnRes[seq[byte]].ok(encode(msg[]))
  ctx[].result = isolate(move r)

proc readLoop*(self: NetworkPeer, conn: Connection) {.async: (raises: []).} =
  if isNil(conn):
    trace "No connection to read from", peer = self.id
    return

  trace "Attaching read loop", peer = self.id, connId = conn.oid
  try:
    while not conn.atEof or not conn.closed:
      var
        data = await conn.readLp(MaxMessageSize.int)
        decodeStart = Moment.now()

      var msg: Message
      if not self.taskpool.isNil and data.len > OffloadThreshold:
        # Offload decode to the taskpool for large payloads. The worker
        # borrows the payload by pointer (the caller's frame outlives
        # the worker via awaitSpawn's drain - zero refcount operations
        # on the payload). Block refs are created and moved on the
        # worker. With `{.acyclic.}` on Block the decrefs are plain (no
        # cycle-registry involvement), so cross-thread destroy is safe.
        msg = (
          await spawnJoin[Message](
            proc(ctx: SharedPtr[TaskCtx[Message]]) {.gcsafe, raises: [].} =
              self.taskpool.spawn decodeMsgTask(ctx, addr data)
          )
        ).tryGet()
      else:
        msg = Message.decode(data).mapFailure().tryGet()

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
    kind = messageKind(msg)
    encodeStart = Moment.now()

  var encoded: seq[byte]
  if not self.taskpool.isNil and
      foldl(msg.payload, a + b.blk.data.len, 0) > OffloadThreshold:
    # Offload encode to the taskpool for payloads with significant block
    # data. The worker borrows the message by pointer. The caller's message
    # and the engine's blk refs survive to the main thread for deterministic
    # destroy.
    encoded = ?await spawnJoin[seq[byte]](
      proc(ctx: SharedPtr[TaskCtx[seq[byte]]]) {.gcsafe, raises: [].} =
        self.taskpool.spawn encodeMsgTask(ctx, addr msg)
    )
  else:
    encoded = encode(msg)

  let encodeNs = (Moment.now() - encodeStart).nanoseconds

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
