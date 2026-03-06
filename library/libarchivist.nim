## libarchivist.nim - C-exported interface for the Archivist shared library
##
## This file implements the public C API for libarchivist.
## It acts as the bridge between C programs and the internal Nim implementation.
##
## This file defines:
## - Initialization logic for the Nim runtime (once per process)
## - Thread-safe exported procs callable from C
## - Callback registration and invocation for asynchronous communication

{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}

{.passc: "-fPIC".}

when defined(linux):
  {.passl: "-Wl,-soname,libarchivist.so".}

import std/[atomics, json]
import chronicles
import chronos
import chronos/threadsync
import ./archivist_context
import ./archivist_thread_requests/archivist_thread_request
import ./archivist_thread_requests/requests/node_lifecycle_request
import ./archivist_thread_requests/requests/node_info_request
import ./archivist_thread_requests/requests/node_debug_request
import ./archivist_thread_requests/requests/node_p2p_request
import ./archivist_thread_requests/requests/node_upload_request
import ./archivist_thread_requests/requests/node_download_request
import ./archivist_thread_requests/requests/node_storage_request
import ./ffi_types
import ./alloc
import ./toml_validation

logScope:
  topics = "libarchivist"

template checkLibarchivistParams*(
    ctx: ptr ArchivistContext, callback: ArchivistCallback, userData: pointer
) =
  let validationResult = validateParams(cast[pointer](ctx), callback)
  if validationResult != RET_OK:
    return validationResult
  
  if not isNil(ctx):
    ctx[].userData = userData

template handleRequestResult*(
    result: Result[void, string],
    request: pointer,
    callback: ArchivistCallback,
    userData: pointer,
    context: string
): cint =
  if result.isErr:
    return handleRequestError(
      callback, userData, RET_THREAD_ERROR, context, $result.error, request,
      proc(req: pointer) {.raises: [].} =
        when compiles(req.cleanupRequest()):
          req.cleanupRequest()
        deallocShared(req)
    )
  else:
    return handleRequestSuccess(callback, userData, "", request,
      proc(req: pointer) {.raises: [].} =
        when compiles(req.cleanupRequest()):
          req.cleanupRequest()
        deallocShared(req)
    )

template handleRequestResultNoCleanup*(
    result: Result[void, string],
    callback: ArchivistCallback,
    userData: pointer,
    context: string
): cint =
  if result.isErr:
    return handleRequestError(callback, userData, RET_THREAD_ERROR, context, $result.error)
  else:
    return handleRequestSuccess(callback, userData)

proc libarchivistNimMain() {.importc.}

var initialized: Atomic[bool]

if defined(android):
  # Redirect chronicles to Android System logs
  when compiles(defaultChroniclesStream.outputs[0].writer):
    defaultChroniclesStream.outputs[0].writer = proc(
        logLevel: LogLevel, msg: LogOutputStr
    ) {.raises: [].} =
      echo logLevel, msg

# Initializes the Nim runtime and foreign-thread GC
proc initializeLibrary() {.exported.} =
  if not initialized.exchange(true):
    libarchivistNimMain()
  when declared(setupForeignThreadGc):
    setupForeignThreadGc()
  when declared(nimGC_setStackBottom):
    var locals {.volatile, noinit.}: pointer
    locals = addr(locals)
    nimGC_setStackBottom(locals)

################################################################################
### Context Lifecycle

proc archivist_new*(
    configToml: cstring, callback: ArchivistCallback, userData: pointer
): pointer {.dynlib, exported.} =
  initializeLibrary()

  let validationResult = validateParams(nil, callback)
  if validationResult != RET_OK:
    let errorMsg = formatErrorMessage(validationResult, "archivist_new", "Callback validation failed")
    if not callback.isNil:
      safeCallback(callback, validationResult, errorMsg, userData)
    return nil

  let tomlValidationResult = validateTomlCString(configToml)
  if tomlValidationResult.isErr:
    let errorMsg = formatErrorMessage(
      RET_INVALID_PARAM,
      "archivist_new",
      "TOML validation failed: " & formatError(tomlValidationResult.error)
    )
    if not callback.isNil:
      safeCallback(callback, RET_INVALID_PARAM, errorMsg, userData)
    return nil

  let safeConfig = if validateCString(configToml): safeStringCopy(configToml, 10000) else: ""

  var ctx = archivist_context.createArchivistContext().valueOr:
    let errorMsg = formatErrorMessage(RET_ERR, "archivist_new", "Failed to create context: " & $error)
    safeCallback(callback, RET_ERR, errorMsg, userData)
    return nil

  ctx.userData = userData

  let reqContent =
    NodeLifecycleRequest.createShared(NodeLifecycleMsgType.CREATE, safeConfig)

  archivist_context.sendRequestToArchivistThread(
    ctx, RequestType.LIFECYCLE, reqContent, callback, userData
  ).isOkOr:
    let errorMsg = formatErrorMessage(RET_THREAD_ERROR, "archivist_new", "Failed to send request: " & $error)
    reqContent.cleanupRequest()
    deallocShared(reqContent)
    safeCallback(callback, RET_THREAD_ERROR, errorMsg, userData)
    return nil

  return ctx

proc archivist_create*(
    ctx: pointer, callback: ArchivistCallback, userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  let req = NodeLifecycleRequest.createShared(NodeLifecycleMsgType.CREATE, "")
  let res = ctx.sendRequestToArchivistThread(RequestType.LIFECYCLE, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_create")

proc archivist_start*(
    ctx: pointer, callback: ArchivistCallback, userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  let req = NodeLifecycleRequest.createShared(NodeLifecycleMsgType.START, "")
  let res = ctx.sendRequestToArchivistThread(RequestType.LIFECYCLE, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_start")

proc archivist_stop*(
    ctx: pointer, callback: ArchivistCallback, userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  let req = NodeLifecycleRequest.createShared(NodeLifecycleMsgType.STOP, "")
  let res = ctx.sendRequestToArchivistThread(RequestType.LIFECYCLE, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_stop")

proc archivist_close*(
    ctx: pointer, callback: ArchivistCallback, userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  # TODO: Need to double check this part
  let ack = "closed"
  return handleRequestSuccess(callback, userData, ack)

proc archivist_destroy*(
    ctx: pointer, callback: ArchivistCallback, userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  let destroyRes = destroyArchivistContext(ctx)
  if destroyRes.isErr:
    return handleRequestError(callback, userData, RET_ERR, "archivist_destroy", $destroyRes.error)
  
  let ack = "destroyed"
  return handleRequestSuccess(callback, userData, ack)

################################################################################
### Version Information

proc archivist_version*(
    ctx: pointer, callback: ArchivistCallback, userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  let req = NodeInfoRequest.createShared(NodeInfoMsgType.VERSION)
  let res = ctx.sendRequestToArchivistThread(RequestType.INFO, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_version")

proc archivist_revision*(
    ctx: pointer, callback: ArchivistCallback, userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  let req = NodeInfoRequest.createShared(NodeInfoMsgType.REVISION)
  let res = ctx.sendRequestToArchivistThread(RequestType.INFO, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_revision")

proc archivist_repo*(
    ctx: pointer, callback: ArchivistCallback, userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  let req = NodeInfoRequest.createShared(NodeInfoMsgType.REPO)
  let res = ctx.sendRequestToArchivistThread(RequestType.INFO, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_repo")

################################################################################
### Debug Operations

proc archivist_debug*(
    ctx: pointer, callback: ArchivistCallback, userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  let req = NodeDebugRequest.createShared(NodeDebugMsgType.DEBUG)
  let res = ctx.sendRequestToArchivistThread(RequestType.DEBUG, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_debug")

proc archivist_spr*(
    ctx: pointer, callback: ArchivistCallback, userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  let req = NodeInfoRequest.createShared(NodeInfoMsgType.SPR)
  let res = ctx.sendRequestToArchivistThread(RequestType.INFO, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_spr")

proc archivist_peer_id*(
    ctx: pointer, callback: ArchivistCallback, userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  let req = NodeInfoRequest.createShared(NodeInfoMsgType.PEERID)
  let res = ctx.sendRequestToArchivistThread(RequestType.INFO, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_peer_id")

proc archivist_log_level*(
    ctx: pointer, logLevel: cstring, callback: ArchivistCallback, userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  
  let safeLogLevel = if validateCString(logLevel): safeStringCopy(logLevel, 50) else: "INFO"
  
  let req = NodeDebugRequest.createShared(NodeDebugMsgType.LOG_LEVEL, safeLogLevel)
  let res = ctx.sendRequestToArchivistThread(RequestType.DEBUG, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_log_level")

################################################################################
### P2P Networking

proc archivist_connect*(
    ctx: pointer,
    peerId: cstring,
    peerAddresses: cstringArray,
    peerAddressesSize: csize_t,
    callback: ArchivistCallback,
    userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  
  let safePeerId = if validateCString(peerId): safeStringCopy(peerId, 500) else: ""
  
  var addresses: seq[string] = @[]
  if not peerAddresses.isNil and peerAddressesSize > 0:
    for i in 0 ..< peerAddressesSize.int:
      if validateCString(peerAddresses[i]):
        addresses.add(safeStringCopy(peerAddresses[i], 1000))
  
  let req = NodeP2PRequest.createShared(NodeP2PMsgType.CONNECT, safePeerId, addresses)
  let res = ctx.sendRequestToArchivistThread(RequestType.P2P, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_connect")

proc archivist_connected_peers*(
    ctx: pointer, callback: ArchivistCallback, userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  let req = NodeP2PRequest.createShared(NodeP2PMsgType.CONNECTED_PEERS)
  let res = ctx.sendRequestToArchivistThread(RequestType.P2P, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_connected_peers")

proc archivist_connected_peer_ids*(
    ctx: pointer, callback: ArchivistCallback, userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  let req = NodeP2PRequest.createShared(NodeP2PMsgType.CONNECTED_PEER_IDS)
  let res = ctx.sendRequestToArchivistThread(RequestType.P2P, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_connected_peer_ids")

proc archivist_find_peer*(
    ctx: pointer, peerId: cstring, callback: ArchivistCallback, userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  let req = NodeP2PRequest.createShared(NodeP2PMsgType.FIND_PEER, $peerId)
  let res = ctx.sendRequestToArchivistThread(RequestType.P2P, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_find_peer")

proc archivist_disconnect*(
    ctx: pointer, peerId: cstring, callback: ArchivistCallback, userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  let req = NodeP2PRequest.createShared(NodeP2PMsgType.DISCONNECT, $peerId)
  let res = ctx.sendRequestToArchivistThread(RequestType.P2P, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_disconnect")

################################################################################
### Upload Operations

proc archivist_upload_init*(
    ctx: pointer,
    filepath: cstring,
    chunkSize: csize_t,
    callback: ArchivistCallback,
    userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  let req = NodeUploadRequest.createShared(NodeUploadMsgType.INIT, $filepath, @[], chunkSize.int)
  let res = ctx.sendRequestToArchivistThread(RequestType.UPLOAD, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_upload_init")

proc archivist_upload_chunk*(
    ctx: pointer,
    sessionId: cstring,
    chunk: ptr uint8,
    len: csize_t,
    callback: ArchivistCallback,
    userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  var chunkData: seq[byte] = @[]
  if not chunk.isNil and len > 0:
    chunkData = newSeq[byte](len.int)
    copyMem(addr chunkData[0], chunk, len.int)
  
  let req = NodeUploadRequest.createShared(NodeUploadMsgType.CHUNK, $sessionId, chunkData)
  let res = ctx.sendRequestToArchivistThread(RequestType.UPLOAD, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_upload_chunk")

proc archivist_upload_finalize*(
    ctx: pointer,
    sessionId: cstring,
    callback: ArchivistCallback,
    userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  let req = NodeUploadRequest.createShared(NodeUploadMsgType.FINALIZE, $sessionId)
  let res = ctx.sendRequestToArchivistThread(RequestType.UPLOAD, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_upload_finalize")

proc archivist_upload_cancel*(
    ctx: pointer,
    sessionId: cstring,
    callback: ArchivistCallback,
    userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  let req = NodeUploadRequest.createShared(NodeUploadMsgType.CANCEL, $sessionId)
  let res = ctx.sendRequestToArchivistThread(RequestType.UPLOAD, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_upload_cancel")

proc archivist_upload_file*(
    ctx: pointer,
    sessionId: cstring,
    callback: ArchivistCallback,
    userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  let req = NodeUploadRequest.createShared(NodeUploadMsgType.FILE, $sessionId)
  let res = ctx.sendRequestToArchivistThread(RequestType.UPLOAD, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_upload_file")

################################################################################
### Download Operations

proc archivist_download_init*(
    ctx: pointer,
    cid: cstring,
    chunkSize: csize_t,
    local: bool,
    callback: ArchivistCallback,
    userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  let req = NodeDownloadRequest.createShared(NodeDownloadMsgType.INIT, $cid, chunkSize.int, local)
  let res = ctx.sendRequestToArchivistThread(RequestType.DOWNLOAD, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_download_init")

proc archivist_download_stream*(
    ctx: pointer,
    cid: cstring,
    chunkSize: csize_t,
    local: bool,
    filepath: cstring,
    callback: ArchivistCallback,
    userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  var fp = ""
  if not filepath.isNil:
    fp = $filepath
  let req = NodeDownloadRequest.createShared(NodeDownloadMsgType.STREAM, $cid, chunkSize.int, local, fp)
  let res = ctx.sendRequestToArchivistThread(RequestType.DOWNLOAD, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_download_stream")

proc archivist_download_chunk*(
    ctx: pointer,
    cid: cstring,
    callback: ArchivistCallback,
    userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  let req = NodeDownloadRequest.createShared(NodeDownloadMsgType.CHUNK, $cid)
  let res = ctx.sendRequestToArchivistThread(RequestType.DOWNLOAD, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_download_chunk")

proc archivist_download_cancel*(
    ctx: pointer,
    cid: cstring,
    callback: ArchivistCallback,
    userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  let req = NodeDownloadRequest.createShared(NodeDownloadMsgType.CANCEL, $cid)
  let res = ctx.sendRequestToArchivistThread(RequestType.DOWNLOAD, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_download_cancel")

proc archivist_download_manifest*(
    ctx: pointer,
    cid: cstring,
    callback: ArchivistCallback,
    userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  let req = NodeDownloadRequest.createShared(NodeDownloadMsgType.MANIFEST, $cid)
  let res = ctx.sendRequestToArchivistThread(RequestType.DOWNLOAD, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_download_manifest")

################################################################################
### Storage Operations

proc archivist_list*(
    ctx: pointer, callback: ArchivistCallback, userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  let req = NodeStorageRequest.createShared(NodeStorageMsgType.LIST)
  let res = ctx.sendRequestToArchivistThread(RequestType.STORAGE, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_list")

proc archivist_space*(
    ctx: pointer, callback: ArchivistCallback, userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  let req = NodeStorageRequest.createShared(NodeStorageMsgType.SPACE)
  let res = ctx.sendRequestToArchivistThread(RequestType.STORAGE, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_space")

proc archivist_delete*(
    ctx: pointer, cid: cstring, callback: ArchivistCallback, userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  let req = NodeStorageRequest.createShared(NodeStorageMsgType.DELETE, cid)
  let res = ctx.sendRequestToArchivistThread(RequestType.STORAGE, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_delete")

proc archivist_fetch*(
    ctx: pointer, cid: cstring, callback: ArchivistCallback, userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  let req = NodeStorageRequest.createShared(NodeStorageMsgType.FETCH, cid)
  let res = ctx.sendRequestToArchivistThread(RequestType.STORAGE, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_fetch")

proc archivist_exists*(
    ctx: pointer, cid: cstring, callback: ArchivistCallback, userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  let req = NodeStorageRequest.createShared(NodeStorageMsgType.EXISTS, cid)
  let res = ctx.sendRequestToArchivistThread(RequestType.STORAGE, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_exists")

proc archivist_local_size*(
    ctx: pointer, callback: ArchivistCallback, userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  let req = NodeStorageRequest.createShared(NodeStorageMsgType.SPACE)
  let res = ctx.sendRequestToArchivistThread(RequestType.STORAGE, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_local_size")

proc archivist_block_count*(
    ctx: pointer, callback: ArchivistCallback, userData: pointer
): cint {.dynlib, exported.} =
  checkLibarchivistParams(cast[ptr ArchivistContext](ctx), callback, userData)
  
  let ctx = cast[ptr ArchivistContext](ctx)
  let req = NodeStorageRequest.createShared(NodeStorageMsgType.SPACE)
  let res = ctx.sendRequestToArchivistThread(RequestType.STORAGE, req, callback, userData)
  return handleRequestResult(res, req, callback, userData, "archivist_block_count")

################################################################################
### Event Callback

proc archivist_set_event_callback*(
    ctx: pointer, callback: ArchivistCallback, userData: pointer
): cint {.dynlib, exported.} =
  let validationResult = validateParams(ctx, callback)
  if validationResult != RET_OK:
    return validationResult
  
  let ctx = cast[ptr ArchivistContext](ctx)
  ctx.eventCallback = cast[pointer](callback)
  ctx.eventUserData = userData
  return RET_OK
