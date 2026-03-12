## FFI Types and Utilities
##
## This file defines the core types and utilities for the library's foreign
## function interface (FFI), enabling interoperability with external code.

{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}

import chronicles
import ./alloc

################################################################################
### FFI utils

template foreignThreadGc*(body: untyped) =
  when declared(setupForeignThreadGc):
    setupForeignThreadGc()

  body

  when declared(tearDownForeignThreadGc):
    tearDownForeignThreadGc()

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
const RET_INVALID_PARAM*: cint = 4
const RET_NULL_CONTEXT*: cint = 5
const RET_THREAD_ERROR*: cint = 6
const RET_MEMORY_ERROR*: cint = 7
const RET_TIMEOUT*: cint = 8

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
  if callback.isNil:
    error "safeCallback: callback is nil"
    cbStr.freeCallbackString()
    return
  
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
### Standardized Error Handling Utilities

proc formatErrorMessage*(errorCode: cint, context: string, details: string = ""): string =
  ## Standardized error message formatting
  let errorType = case errorCode:
    of RET_INVALID_PARAM: "Invalid parameter"
    of RET_NULL_CONTEXT: "Null context"
    of RET_THREAD_ERROR: "Thread error"
    of RET_MEMORY_ERROR: "Memory error"
    of RET_TIMEOUT: "Timeout error"
    of RET_MISSING_CALLBACK: "Missing callback"
    of RET_ERR: "General error"
    else: "Unknown error"
  
  if details.len > 0:
    errorType & " in " & context & ": " & details
  else:
    errorType & " in " & context

proc handleRequestError*(
    callback: ArchivistCallback,
    userData: pointer,
    errorCode: cint,
    context: string,
    details: string = "",
    request: pointer = nil,
    cleanupProc: proc(request: pointer) {.raises: [].} = nil
): cint =
  ## Standardized error handling for failed requests
  ## Handles cleanup and consistent error reporting
  # Defer cleanup until after callback
  if not request.isNil and not cleanupProc.isNil:
    defer:
      cleanupProc(request)
  
  foreignThreadGc:
    let errorMsg = formatErrorMessage(errorCode, context, details)
    safeCallback(callback, errorCode, errorMsg, userData)
  return errorCode

proc handleRequestSuccess*(
    callback: ArchivistCallback,
    userData: pointer,
    message: string = "",
    request: pointer = nil,
    cleanupProc: proc(request: pointer) {.raises: [].} = nil
): cint =
  ## Standardized success handling for completed requests
  ## Handles cleanup and consistent success reporting
  info "handleRequestSuccess: Starting", message = message
  
  # Defer cleanup until after callback
  if not request.isNil and not cleanupProc.isNil:
    defer:
      info "handleRequestSuccess: Calling cleanupProc"
      cleanupProc(request)
      info "handleRequestSuccess: cleanupProc completed"
  
  foreignThreadGc:
    info "handleRequestSuccess: Calling safeCallback"
    safeCallback(callback, RET_OK, message, userData)
    info "handleRequestSuccess: safeCallback completed"
  return RET_OK

proc validateContext*(ctx: pointer): cint =
  ## Standardized context validation
  if ctx.isNil:
    return RET_NULL_CONTEXT
  return RET_OK

proc validateCallback*(callback: ArchivistCallback): cint =
  ## Standardized callback validation
  if callback.isNil:
    return RET_MISSING_CALLBACK
  return RET_OK

proc validateParams*(ctx: pointer, callback: ArchivistCallback): cint =
  ## Standardized parameter validation for common FFI function signature
  let ctxResult = validateContext(ctx)
  if ctxResult != RET_OK:
    return ctxResult
  
  let callbackResult = validateCallback(callback)
  if callbackResult != RET_OK:
    return callbackResult
  
  return RET_OK

type onDone* = proc()
