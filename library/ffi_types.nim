## FFI Types and Utilities
##
## This file defines the core types and utilities for the library's foreign
## function interface (FFI), enabling interoperability with external code.

{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}

import pkg/results

################################################################################
### Exported types

type ArchivistCallback* = proc(
  callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].}

################################################################################
### Return codes

const RET_OK*: cint = 0
const RET_ERR*: cint = 1
const RET_MISSING_CALLBACK*: cint = 2
const RET_PROGRESS*: cint = 3

################################################################################
### Helper procedures

proc success*(callback: ArchivistCallback, msg: string, userData: pointer): cint =
  if msg.len > 0:
    callback(RET_OK, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
  else:
    let empty = ""
    callback(RET_OK, unsafeAddr empty[0], 0, userData)
  return RET_OK

proc error*(callback: ArchivistCallback, msg: string, userData: pointer): cint =
  let msg = "libarchivist error: " & msg
  callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
  return RET_ERR

proc okOrError*[T](
    callback: ArchivistCallback, res: Result[T, string], userData: pointer
): cint =
  if res.isOk:
    return RET_OK
  return callback.error($res.error, userData)

proc progress*(callback: ArchivistCallback, data: string, userData: pointer): cint =
  callback(RET_PROGRESS, unsafeAddr data[0], cast[csize_t](len(data)), userData)
  return RET_OK

################################################################################
### FFI utils

template foreignThreadGc*(body: untyped) =
  when declared(setupForeignThreadGc):
    setupForeignThreadGc()

  body

  when declared(tearDownForeignThreadGc):
    tearDownForeignThreadGc()

type onDone* = proc()
