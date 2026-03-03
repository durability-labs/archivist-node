## This file contains the base message request type that will be handled.
## The requests are created by the main thread and processed by
## the Archivist Thread.

import std/json
import results
import chronos
import ../ffi_types
import ./requests/node_lifecycle_request
import ./requests/node_info_request
import ./requests/node_debug_request
import ./requests/node_p2p_request
import ./requests/node_upload_request
import ./requests/node_download_request
import ./requests/node_storage_request

from ../../archivist/archivist import NodeServer

type RequestType* {.pure.} = enum
  LIFECYCLE
  INFO
  DEBUG
  P2P
  UPLOAD
  DOWNLOAD
  STORAGE

type ArchivistThreadRequest* = object
  reqType: RequestType

  reqContent: pointer

  callback: ArchivistCallback

  userData: pointer

proc createShared*(
    T: type ArchivistThreadRequest,
    reqType: RequestType,
    reqContent: pointer,
    callback: ArchivistCallback,
    userData: pointer,
): ptr type T =
  var ret = createShared(T)
  ret[].reqType = reqType
  ret[].reqContent = reqContent
  ret[].callback = callback
  ret[].userData = userData
  return ret

# TODO: Look into how to improve callback handling (thread pool/mp channel)
proc handleRes[T: string | void | seq[byte]](
    res: Result[T, string], request: ptr ArchivistThreadRequest
) =
  defer:
    deallocShared(request)

  if res.isErr():
    foreignThreadGc:
      let msg = $res.error
      if msg == "":
        request[].callback(RET_ERR, nil, cast[csize_t](0), request[].userData)
      else:
        request[].callback(
          RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), request[].userData
        )
    return

  foreignThreadGc:
    var msg: cstring = ""
    when T is string:
      msg = res.get().cstring()
    request[].callback(
      RET_OK, unsafeAddr msg[0], cast[csize_t](len(msg)), request[].userData
    )
  return

proc process*(
    T: type ArchivistThreadRequest,
    request: ptr ArchivistThreadRequest,
    archivist: ptr NodeServer,
) {.async: (raises: []).} =
  let retFut =
    case request[].reqType
    of LIFECYCLE:
      cast[ptr NodeLifecycleRequest](request[].reqContent).process(archivist)
    of INFO:
      cast[ptr NodeInfoRequest](request[].reqContent).process(archivist)
    of RequestType.DEBUG:
      cast[ptr NodeDebugRequest](request[].reqContent).process(archivist)
    of P2P:
      cast[ptr NodeP2PRequest](request[].reqContent).process(archivist)
    of STORAGE:
      cast[ptr NodeStorageRequest](request[].reqContent).process(archivist)
    of DOWNLOAD:
      let onChunk = proc(bytes: seq[byte]) =
        if bytes.len > 0:
          request[].callback(
            RET_PROGRESS,
            cast[ptr cchar](unsafeAddr bytes[0]),
            cast[csize_t](bytes.len),
            request[].userData,
          )

      cast[ptr NodeDownloadRequest](request[].reqContent).process(archivist, onChunk)
    of UPLOAD:
      let onBlockReceived = proc(bytes: int) =
        request[].callback(RET_PROGRESS, nil, cast[csize_t](bytes), request[].userData)

      cast[ptr NodeUploadRequest](request[].reqContent).process(
        archivist, onBlockReceived
      )

  handleRes(await retFut, request)

proc `$`*(self: ArchivistThreadRequest): string =
  return $self.reqType
