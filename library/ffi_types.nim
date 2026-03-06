## FFI Types and Utilities
##
## This file defines the core types and utilities for the library's foreign
## function interface (FFI), enabling interoperability with external code.

{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}

import ./alloc

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
### Safe callback string handling

type CallbackString* = object
  data*: cstring
  len*: csize_t

proc createCallbackString*(msg: string): CallbackString =
  if msg.len == 0:
    return CallbackString(data: nil, len: 0)
  
  let data = allocCString(msg)
  return CallbackString(data: data, len: cast[csize_t](msg.len))

proc createCallbackString*(msg: cstring): CallbackString =
  if msg.isNil:
    return CallbackString(data: nil, len: 0)
  
  let len = len(msg)
  if len == 0:
    return CallbackString(data: nil, len: 0)
  
  let data = alloc(msg)
  return CallbackString(data: data, len: cast[csize_t](len))

proc freeCallbackString*(cbStr: CallbackString) =
  if not cbStr.data.isNil:
    deallocCString(cbStr.data)

proc safeCallback*(callback: ArchivistCallback, retCode: cint, cbStr: CallbackString, userData: pointer) =
  callback(retCode, cast[ptr cchar](cbStr.data), cbStr.len, userData)
  cbStr.freeCallbackString()

proc safeCallback*(callback: ArchivistCallback, retCode: cint, msg: string, userData: pointer) =
  let cbStr = createCallbackString(msg)
  safeCallback(callback, retCode, cbStr, userData)

################################################################################
### String pointer validation

proc validateCString*(str: cstring): bool =
  return not str.isNil

proc validateStringPtr*(strPtr: ptr cchar, len: csize_t): bool =
  return not strPtr.isNil and len > 0

proc safeStringCopy*(src: cstring, maxLen: csize_t): string =
  if not validateCString(src):
    return ""
  
  try:
    let srcLen = len(src)
    let copyLen = min(srcLen, maxLen.int)
    if copyLen == 0:
      return ""
    
    result = newString(copyLen)
    copyMem(addr result[0], src, copyLen)
  except:
    result = ""

################################################################################
### Helper procedures

proc success*(callback: ArchivistCallback, msg: string, userData: pointer): cint =
  safeCallback(callback, RET_OK, msg, userData)
  return RET_OK

proc error*(callback: ArchivistCallback, msg: string, userData: pointer): cint =
  let fullMsg = "libarchivist error: " & msg
  safeCallback(callback, RET_ERR, fullMsg, userData)
  return RET_ERR

proc progress*(callback: ArchivistCallback, data: string, userData: pointer): cint =
  safeCallback(callback, RET_PROGRESS, data, userData)
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
