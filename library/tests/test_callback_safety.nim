## Test Callback Safety
##
## This file tests the safe string pointer usage in callbacks to ensure
## memory safety and thread safety are properly handled.

import std/[unittest, strutils, os]
import ffi_types
import alloc

suite "Callback Safety Tests":

  test "safeCallback with empty string":
    var callbackCalled = false
    var callbackRetCode: cint
    var callbackUserData: pointer
    
    let testCallback = proc(retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer) {.cdecl, gcsafe, raises: [].} =
      callbackCalled = true
      callbackRetCode = retCode
      callbackUserData = userData
    
    let userData = cast[pointer](0x12345)
    safeCallback(testCallback, RET_OK, "", userData)
    
    check(callbackCalled)
    check(callbackRetCode == RET_OK)
    check(callbackUserData == userData)

  test "safeCallback with non-empty string":
    var callbackCalled = false
    
    let testCallback = proc(retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer) {.cdecl, gcsafe, raises: [].} =
      callbackCalled = true
      # Just verify the callback was called with non-nil message
      if not msg.isNil and len > 0:
        # Message is valid
        discard
    
    let testMsg = "Hello, World!"
    safeCallback(testCallback, RET_ERR, testMsg, nil)
    
    check(callbackCalled)

  test "createCallbackString with empty string":
    let cbStr = createCallbackString("")
    check(cbStr.data.isNil)
    check(cbStr.len == cast[csize_t](0))
    cbStr.freeCallbackString()

  test "createCallbackString with non-empty string":
    let testMsg = "Test message"
    let cbStr = createCallbackString(testMsg)
    check(not cbStr.data.isNil)
    check(cbStr.len == cast[csize_t](testMsg.len))
    cbStr.freeCallbackString()

  test "createCallbackString with cstring":
    let testMsg = "C string test"
    let cStr = testMsg.cstring
    let cbStr = createCallbackString(cStr)
    check(not cbStr.data.isNil)
    check(cbStr.len == cast[csize_t](testMsg.len))
    cbStr.freeCallbackString()

  test "validateCString with valid string":
    let testMsg = "Valid string"
    let cStr = testMsg.cstring
    check(validateCString(cStr))

  test "validateCString with nil string":
    let cStr: cstring = nil
    check(not validateCString(cStr))

  test "validateStringPtr with valid pointer":
    let testMsg = "Valid pointer test"
    var msgCopy = testMsg
    let msgPtr = cast[ptr cchar](addr msgCopy[0])
    check(validateStringPtr(msgPtr, cast[csize_t](testMsg.len)))

  test "validateStringPtr with nil pointer":
    let msgPtr: ptr cchar = nil
    check(not validateStringPtr(msgPtr, cast[csize_t](10)))

  test "safeStringCopy with valid cstring":
    let testMsg = "Safe copy test"
    let cStr = testMsg.cstring
    let copied = safeStringCopy(cStr, cast[csize_t](100))
    check(copied == testMsg)

  test "safeStringCopy with nil cstring":
    let cStr: cstring = nil
    let copied = safeStringCopy(cStr, cast[csize_t](100))
    check(copied == "")

  test "safeStringCopy with length limit":
    let testMsg = "This is a long string that should be truncated"
    let cStr = testMsg.cstring
    let copied = safeStringCopy(cStr, cast[csize_t](10))
    check(copied.len <= 10)

  test "success helper function":
    var callbackCalled = false
    
    let testCallback = proc(retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer) {.cdecl, gcsafe, raises: [].} =
      callbackCalled = true
    
    let result = success(testCallback, "Success message", nil)
    check(result == RET_OK)
    check(callbackCalled)

  test "error helper function":
    var callbackCalled = false
    
    let testCallback = proc(retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer) {.cdecl, gcsafe, raises: [].} =
      callbackCalled = true
    
    let result = error(testCallback, "Test error", nil)
    check(result == RET_ERR)
    check(callbackCalled)

  test "progress helper function":
    var callbackCalled = false
    
    let testCallback = proc(retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer) {.cdecl, gcsafe, raises: [].} =
      callbackCalled = true
    
    let result = progress(testCallback, "Progress data", nil)
    check(result == RET_OK)
    check(callbackCalled)

  test "SharedSeq allocation and deallocation":
    let originalSeq = @[1'u8, 2'u8, 3'u8, 4'u8, 5'u8]
    var sharedSeq = allocSharedSeq(originalSeq)
    
    check(sharedSeq.len == originalSeq.len)
    check(not sharedSeq.data.isNil)
    
    # Verify content
    for i in 0..<sharedSeq.len:
      check(sharedSeq.data[i] == originalSeq[i])
    
    # Convert back to seq
    let convertedSeq = toSeq(sharedSeq)
    check(convertedSeq == originalSeq)
    
    # Clean up
    deallocSharedSeq(sharedSeq)

  test "Thread safety simulation":
    # This test simulates concurrent callback usage
    var callbackCount = 0
    
    let testCallback = proc(retCode: cint, msg: ptr cchar, len: csize_t, userData: pointer) {.cdecl, gcsafe, raises: [].} =
      atomicInc(callbackCount)
      # Simulate some work with the message
      if not msg.isNil and len > 0:
        # Message is valid
        discard
    
    # Call callback multiple times with different messages
    for i in 0..<10:
      let msg = "Message " & $i
      safeCallback(testCallback, RET_OK, msg, nil)
    
    check(callbackCount == 10)

when isMainModule:
  echo "Running callback safety tests..."