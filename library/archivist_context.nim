## Archivist Context and Thread Management
##
## This file defines the Archivist context and its thread flow:
## 1. Client enqueues a request and signals the Archivist thread.
## 2. The Archivist thread dequeues the request and sends an ack (reqReceivedSignal).
## 3. The Archivist thread executes the request asynchronously.
## 4. On completion, the Archivist thread invokes the client callback with the result and userData.

{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}
{.passc: "-fPIC".}

import std/[options, locks, atomics]
import chronicles
import chronos
import chronos/threadsync
import taskpools/channels_spsc_single
import ./ffi_types
import ./archivist_thread_requests/[archivist_thread_request]
import ./archivist_thread_requests/requests/node_lifecycle_request

import ../archivist/archivist

logScope:
  topics = "libarchivist"

type ArchivistContext* = object
  thread: Thread[(ptr ArchivistContext)]

  # TODO: Should probably use a MP Channel insted of SP to process requests concurrently
  lock: Lock

  reqChannel: ChannelSPSCSingle[ptr ArchivistThreadRequest]

  reqSignal: ThreadSignalPtr

  reqReceivedSignal: ThreadSignalPtr

  userData*: pointer

  eventCallback*: pointer

  eventUserData*: pointer

  running: Atomic[bool]
  
  archivist: ptr NodeServer

template callEventCallback(ctx: ptr ArchivistContext, eventName: string, body: untyped) =
  if isNil(ctx[].eventCallback):
    error eventName & " - eventCallback is nil"
    return

  foreignThreadGc:
    try:
      let event = body
      safeCallback(cast[ArchivistCallback](ctx[].eventCallback), RET_OK, event, ctx[].eventUserData)
    except CatchableError:
      let msg =
        "Exception " & eventName & " when calling 'eventCallBack': " &
        getCurrentExceptionMsg()
      safeCallback(cast[ArchivistCallback](ctx[].eventCallback), RET_ERR, msg, ctx[].eventUserData)

proc sendRequestToArchivistThread*(
    ctx: ptr ArchivistContext,
    reqType: RequestType,
    reqContent: pointer,
    callback: ArchivistCallback,
    userData: pointer,
    timeout = InfiniteDuration,
): Result[void, string] =
  ctx.lock.acquire()

  defer:
    ctx.lock.release()

  let req = ArchivistThreadRequest.createShared(reqType, reqContent, callback, userData)

  let sentOk = ctx.reqChannel.trySend(req)
  if not sentOk:
    deallocShared(req)
    return err("Failed to send request to the Archivist thread: " & $req[])

  let fireSyncRes = ctx.reqSignal.fireSync()
  if fireSyncRes.isErr():
    deallocShared(req)
    return err(
      "Failed to send request to the Archivist thread: unable to fireSync: " &
        $fireSyncRes.error
    )

  if fireSyncRes.get() == false:
    deallocShared(req)
    return
      err("Failed to send request to the Archivist thread: fireSync timed out.")

  let res = ctx.reqReceivedSignal.waitSync(timeout)
  if res.isErr():
    deallocShared(req)
    return err(
      "Failed to send request to the Archivist thread: unable to receive reqReceivedSignal signal."
    )

  ok()

proc runArchivist(ctx: ptr ArchivistContext) {.async: (raises: []).} =
  var archivist: NodeServer
  ctx.archivist = addr archivist

  while true:
    try:
      await ctx.reqSignal.wait()
    except Exception as e:
      error "Failure in run Archivist thread while waiting for reqSignal.",
        error = e.msg
      continue

    if ctx.running.load == false:
      try:
        await archivist.stop()
      except Exception as e:
        error "runArchivist: Failed to stop archivist", error = e.msg

      break

    var request: ptr ArchivistThreadRequest

    let recvOk = ctx.reqChannel.tryRecv(request)
    if not recvOk:
      error "Failure in run Archivist: unable to receive request in Archivist thread."
      continue

    let req = request
    asyncSpawn (
      proc() {.async.} =
        await sleepAsync(0)
        await ArchivistThreadRequest.process(req, addr archivist)
    )()

    let fireRes = ctx.reqReceivedSignal.fireSync()
    if fireRes.isErr():
      error "Failure in run Archivist: unable to fire back to requester thread.",
        error = fireRes.error

proc run(ctx: ptr ArchivistContext) {.thread.} =
  waitFor runArchivist(ctx)

proc createArchivistContext*(): Result[ptr ArchivistContext, string] =
  var ctx = createShared(ArchivistContext, 1)

  ctx.reqSignal = ThreadSignalPtr.new().valueOr:
    return
      err("Failed to create a context: unable to create reqSignal ThreadSignalPtr.")

  ctx.reqReceivedSignal = ThreadSignalPtr.new().valueOr:
    return err(
      "Failed to create Archivist context: unable to create reqReceivedSignal ThreadSignalPtr."
    )

  ctx.lock.initLock()
  
  ctx.archivist = nil
  ctx.running.store(true)

  try:
    createThread(ctx.thread, run, ctx)
  except ValueError, ResourceExhaustedError:
    freeShared(ctx)
    return err(
      "Failed to create Archivist context: unable to create thread: " &
        getCurrentExceptionMsg()
    )

  return ok(ctx)

proc destroyArchivistContext*(ctx: ptr ArchivistContext): Result[void, string] =
  ctx.running.store(false)
  let signaledOnTime = ctx.reqSignal.fireSync().valueOr:
    return err("Failed to destroy Archivist context: " & $error)

  if not signaledOnTime:
    return err(
      "Failed to destroy Archivist context: unable to get signal reqSignal on time in destroyArchivistContext."
    )

  joinThread(ctx.thread)

  ctx.lock.deinitLock()
  ?ctx.reqSignal.close()
  ?ctx.reqReceivedSignal.close()
  freeShared(ctx)

  return ok()
