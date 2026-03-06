#!/usr/bin/env nim
## Test runner for library tests

import os, strutils

proc runTest(testFile: string): bool =
  echo "Running test: ", testFile
  let cmd = "nim c -r --hints:off " & testFile
  let exitCode = execShellCmd(cmd)
  if exitCode == 0:
    echo "✓ ", testFile, " passed"
    return true
  else:
    echo "✗ ", testFile, " failed (exit code: ", exitCode, ")"
    return false

proc main() =
  let testDir = getCurrentDir()
  let nimTests = toSeq(walkFiles(testDir / "test_*.nim"))
  
  if nimTests.len == 0:
    echo "No Nim tests found in ", testDir
    return
  
  echo "Running ", nimTests.len, " Nim test(s)..."
  echo "=" .repeat(50)
  
  var passed = 0
  var failed = 0
  
  for test in nimTests:
    if runTest(test):
      inc passed
    else:
      inc failed
    echo ""
  
  echo "=" .repeat(50)
  echo "Results: ", passed, " passed, ", failed, " failed"
  
  if failed > 0:
    quit(1)

when isMainModule:
  main()