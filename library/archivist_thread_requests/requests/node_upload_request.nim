## This file contains the upload request.
## A session is created for each upload allowing to resume,
## pause and cancel uploads (using chunks).
##
## There are two ways to upload a file:
## 1. Via chunks: the filepath parameter is the data filename. Steps are:
##  - INIT: creates a new upload session and returns its ID.
##  - CHUNK: sends a chunk of data to the upload session.
##  - FINALIZE: finalizes the upload and returns the CID of the uploaded file.
##  - CANCEL: cancels the upload session.
##
## 2. Directly from a file path: the filepath has to be absolute.
##  - INIT: creates a new upload session and returns its ID
##  - FILE: starts the upload and returns the CID of the uploaded file
##  - CANCEL: cancels the upload session.

{.push raises: [].}

import std/[options, os, mimetypes]
import chronos
import chronicles
import questionable
import questionable/results
import faststreams/inputs
import libp2p/stream/[bufferstream, lpstream]
import ../../alloc
import ../../../archivist/units
import ../../../archivist/blocktype as bt

from "../../../archivist/archivist" import NodeServer
from ../../../archivist/node import ArchivistNodeRef, store
from libp2p import Cid, `$`

logScope:
  topics = "libarchivist libarchivistupload"

type NodeUploadMsgType* = enum
  INIT
  CHUNK
  FINALIZE
  CANCEL
  FILE

type OnProgressHandler = proc(bytes: int): void {.gcsafe, raises: [].}

type NodeUploadRequest* = object
  operation: NodeUploadMsgType
  sessionId: cstring
  filepath: cstring
  chunk: seq[byte]
  chunkSize: csize_t

type
  UploadSessionId* = string
  UploadSessionCount* = int
  UploadSession* = object
    stream: BufferStream
    fut: Future[?!Cid]
    filepath: string
    chunkSize: int
    onProgress: OnProgressHandler

var uploadSessions {.threadvar.}: Table[UploadSessionId, UploadSession]
var nextUploadSessionCount {.threadvar.}: UploadSessionCount

proc createShared*(
    T: type NodeUploadRequest,
    op: NodeUploadMsgType,
    data: string = "",
    chunk: seq[byte] = @[],
    chunkSize: int = 0
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  if op == NodeUploadMsgType.INIT:
    ret[].filepath = data.alloc()
    ret[].sessionId = "".alloc()
  else:
    ret[].sessionId = data.alloc()
    ret[].filepath = "".alloc()
  ret[].chunk = chunk
  ret[].chunkSize = csize_t(chunkSize)
  return ret

proc destroyShared(self: ptr NodeUploadRequest) =
  deallocShared(self[].filepath)
  deallocShared(self[].sessionId)
  deallocShared(self)

proc init(
    archivist: ptr NodeServer, filepath: cstring = "", chunkSize: csize_t = 0
): Future[Result[string, string]] {.async: (raises: []).} =
  var filenameOpt, mimetypeOpt = string.none

  if isAbsolute($filepath):
    if not fileExists($filepath):
      return err(
        "Failed to create an upload session, the filepath does not exist: " & $filepath
      )

  if filepath != "":
    let (_, name, ext) = splitFile($filepath)
    filenameOpt = (name & ext).some

    if ext != "":
      let extNoDot =
        if ext.len > 0:
          ext[1 ..^ 1]
        else:
          ""
      let mime = newMimetypes()
      let mimetypeStr = mime.getMimetype(extNoDot, "")
      mimetypeOpt = if mimetypeStr == "": string.none else: mimetypeStr.some

  let sessionId = $nextUploadSessionCount
  nextUploadSessionCount.inc()

  let stream = BufferStream.new()
  let lpStream = LPStream(stream)

  let blockSize =
    if chunkSize.NBytes > 0.NBytes: chunkSize.NBytes else: DefaultBlockSize
  
  let fut = archivist[].archivistNode.store(lpStream, filenameOpt, mimetypeOpt, blockSize)

  uploadSessions[sessionId] = UploadSession(
    stream: stream, fut: fut, filepath: $filepath, chunkSize: blockSize.int
  )

  return ok(sessionId)

proc chunk(
    archivist: ptr NodeServer, sessionId: cstring, chunk: seq[byte]
): Future[Result[string, string]] {.async: (raises: []).} =
  if not uploadSessions.contains($sessionId):
    return err("Failed to upload the chunk, the session is not found: " & $sessionId)

  var fut = newFuture[void]()

  try:
    let session = uploadSessions[$sessionId]

    if chunk.len >= session.chunkSize:
      uploadSessions[$sessionId].onProgress = proc(
          bytes: int
      ): void {.gcsafe, raises: [].} =
        fut.complete()
      await session.stream.pushData(chunk)
    else:
      fut = session.stream.pushData(chunk)

    await fut
    uploadSessions[$sessionId].onProgress = nil
  except KeyError:
    return err("Failed to upload the chunk, the session is not found: " & $sessionId)
  except LPError as e:
    return err("Failed to upload the chunk, stream error: " & $e.msg)
  except CancelledError:
    return err("Failed to upload the chunk, operation cancelled.")
  except CatchableError as e:
    return err("Failed to upload the chunk: " & $e.msg)
  finally:
    if not fut.finished():
      fut.cancelSoon()

  return ok("")

proc finalize(
    archivist: ptr NodeServer, sessionId: cstring
): Future[Result[string, string]] {.async: (raises: []).} =
  if not uploadSessions.contains($sessionId):
    return err("Failed to finalize the upload session, session not found: " & $sessionId)

  var session: UploadSession
  try:
    session = uploadSessions[$sessionId]
    await session.stream.pushEof()

    let res = await session.fut
    if res.isErr:
      return err("Failed to finalize the upload session: " & res.error().msg)

    return ok($res.get())
  except KeyError:
    return err("Failed to finalize the upload session, invalid session ID: " & $sessionId)
  except LPStreamError as e:
    return err("Failed to finalize the upload session, stream error: " & $e.msg)
  except CancelledError:
    return err("Failed to finalize the upload session, operation cancelled")
  except CatchableError as e:
    return err("Failed to finalize the upload session: " & $e.msg)
  finally:
    if uploadSessions.contains($sessionId):
      uploadSessions.del($sessionId)

    if session.fut != nil and not session.fut.finished():
      session.fut.cancelSoon()

proc cancel(
    archivist: ptr NodeServer, sessionId: cstring
): Future[Result[string, string]] {.async: (raises: []).} =
  if not uploadSessions.contains($sessionId):
    return ok("")

  try:
    let session = uploadSessions[$sessionId]
    session.fut.cancelSoon()
  except KeyError:
    return ok("")

  uploadSessions.del($sessionId)
  return ok("")

proc streamFile(
    filepath: string, stream: BufferStream, chunkSize: int
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  try:
    let inputStreamHandle = filepath.fileInput()
    let inputStream = inputStreamHandle.implicitDeref

    var buf = newSeq[byte](chunkSize)
    while inputStream.readable:
      let read = inputStream.readIntoEx(buf)
      if read == 0:
        break
      await stream.pushData(buf[0 ..< read])
    return ok()
  except IOError, OSError, LPStreamError:
    let e = getCurrentException()
    return err("Failed to stream the file: " & $e.msg)

proc file(
    archivist: ptr NodeServer, sessionId: cstring, onProgress: OnProgressHandler
): Future[Result[string, string]] {.async: (raises: []).} =
  if not uploadSessions.contains($sessionId):
    return err("Failed to upload the file, invalid session ID: " & $sessionId)

  var session: UploadSession

  try:
    uploadSessions[$sessionId].onProgress = onProgress
    session = uploadSessions[$sessionId]

    let res = await streamFile(session.filepath, session.stream, session.chunkSize)
    if res.isErr:
      return err("Failed to upload the file: " & res.error)

    return await archivist.finalize(sessionId)
  except KeyError:
    return err("Failed to upload the file, the session is not found: " & $sessionId)
  except LPStreamError, IOError:
    let e = getCurrentException()
    return err("Failed to upload the file: " & $e.msg)
  except CancelledError:
    return err("Failed to upload the file, the operation is cancelled.")
  except CatchableError as e:
    return err("Failed to upload the file: " & $e.msg)
  finally:
    if uploadSessions.contains($sessionId):
      uploadSessions.del($sessionId)

    if session.fut != nil and not session.fut.finished():
      session.fut.cancelSoon()

proc process*(
    self: ptr NodeUploadRequest,
    archivist: ptr NodeServer,
    onUploadProgress: OnProgressHandler = nil,
): Future[Result[string, string]] {.async: (raises: []).} =
  defer:
    destroyShared(self)

  case self.operation
  of NodeUploadMsgType.INIT:
    let res = (await init(archivist, self.filepath, self.chunkSize))
    if res.isErr:
      error "Failed to INIT.", error = res.error
      return err($res.error)
    return res
  of NodeUploadMsgType.CHUNK:
    let res = (await chunk(archivist, self.sessionId, self.chunk))
    if res.isErr:
      error "Failed to CHUNK.", error = res.error
      return err($res.error)
    return res
  of NodeUploadMsgType.FINALIZE:
    let res = (await finalize(archivist, self.sessionId))
    if res.isErr:
      error "Failed to FINALIZE.", error = res.error
      return err($res.error)
    return res
  of NodeUploadMsgType.CANCEL:
    let res = (await cancel(archivist, self.sessionId))
    if res.isErr:
      error "Failed to CANCEL.", error = res.error
      return err($res.error)
    return res
  of NodeUploadMsgType.FILE:
    let res = (await file(archivist, self.sessionId, onUploadProgress))
    if res.isErr:
      error "Failed to FILE.", error = res.error
      return err($res.error)
    return res
