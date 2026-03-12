## Test file for standardized error handling
## This file tests the new error handling patterns

import std/[unittest, strutils]
import ./ffi_types

suite "Standardized Error Handling Tests":
  
  test "Error code constants are defined":
    check RET_OK == 0
    check RET_ERR == 1
    check RET_MISSING_CALLBACK == 2
    check RET_PROGRESS == 3
    check RET_INVALID_PARAM == 4
    check RET_NULL_CONTEXT == 5
    check RET_THREAD_ERROR == 6
    check RET_MEMORY_ERROR == 7
    check RET_TIMEOUT == 8

  test "formatErrorMessage creates consistent error messages":
    let msg1 = formatErrorMessage(RET_ERR, "test_function", "Something went wrong")
    check msg1 == "General error in test_function: Something went wrong"
    
    let msg2 = formatErrorMessage(RET_INVALID_PARAM, "validate_input", "Invalid CID format")
    check msg2 == "Invalid parameter in validate_input: Invalid CID format"
    
    let msg3 = formatErrorMessage(RET_NULL_CONTEXT, "archivist_create")
    check msg3 == "Null context in archivist_create"
    
    let msg4 = formatErrorMessage(RET_THREAD_ERROR, "send_request", "Thread communication failed")
    check msg4 == "Thread error in send_request: Thread communication failed"

  test "validateContext returns correct error codes":
    check validateContext(nil) == RET_NULL_CONTEXT
    check validateContext(cast[pointer](0x1234)) == RET_OK

  test "validateCallback returns correct error codes":
    check validateCallback(nil) == RET_MISSING_CALLBACK
    # Create a dummy callback for testing
    let dummyCallback: ArchivistCallback = proc(callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer) {.cdecl, gcsafe, raises: [].} = discard
    check validateCallback(dummyCallback) == RET_OK

  test "validateParams combines context and callback validation":
    let dummyCallback: ArchivistCallback = proc(callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer) {.cdecl, gcsafe, raises: [].} = discard
    
    # Both null
    check validateParams(nil, nil) == RET_NULL_CONTEXT
    
    # Context null, callback valid
    check validateParams(nil, dummyCallback) == RET_NULL_CONTEXT
    
    # Context valid, callback null
    check validateParams(cast[pointer](0x1234), nil) == RET_MISSING_CALLBACK
    
    # Both valid
    check validateParams(cast[pointer](0x1234), dummyCallback) == RET_OK

  test "Error message formatting handles edge cases":
    # Empty details
    let msg1 = formatErrorMessage(RET_ERR, "test", "")
    check msg1 == "General error in test"
    
    # Unknown error code
    let msg2 = formatErrorMessage(999, "unknown_function", "Unknown error")
    check msg2 == "Unknown error in unknown_function: Unknown error"

when isMainModule:
  echo "Running standardized error handling tests..."
  echo "All tests should pass to verify the error handling standardization works correctly."