version = "0.1.0"
author = "Archivist Team"
description = "data durability engine"
license = "MIT"
bin = @["archivist", "tools/cirdl/cirdl", "tools/setup/setup"]
binDir = "build"

import std/os

before build:
  exec "nim vendor" / "nimble" / "install.nims"

task test, "Run node tests":
  exec "nim c -r tests" / "testNode"

task testContracts, "Run contract tests":
  exec "nim c -r tests" / "testContracts"

task testIntegration, "Run integration tests":
  exec "nim c" &
    " --define:release" &
    " --define:archivist_system_testing_options" &
    " --out:build" / "integration-test" / "archivist-for-testing".toExe &
    " archivist"
  exec "nim c -r tests" / "testIntegration"

task testTools, "Run circuit downloader tests":
  exec "nimble build"
  exec "nim c -r tests" / "testTools"

task testAll, "Run all tests":
  testTask()
  testContractsTask()
  testIntegrationTask()
  testToolsTask()

task format, "Format code using NPH":
  exec "nimble install https://github.com/durability-labs/nph@#version-0-6-2-prerelease" # TODO: update to version 0.6.2 once it is released
  exec findExe("nph") & " archivist.nim"
  exec findExe("nph") & " archivist/"
  exec findExe("nph") & " tests/"
  exec findExe("nph") & " tools/"
