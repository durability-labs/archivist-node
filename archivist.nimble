version = "0.1.0"
author = "Archivist Team"
description = "data durability engine"
license = "MIT"
bin = @["archivist", "tools/cirdl/cirdl"]
binDir = "build"

requires "https://github.com/durability-labs/nim-libp2p#multihash-poseidon2"
requires "https://github.com/durability-labs/archivist-dht >= 0.7.1"
requires "https://github.com/durability-labs/nim-ethers >= 3.1.0"
requires "https://github.com/status-im/nim-toml-serialization >= 0.2.14"
requires "https://github.com/status-im/lrucache.nim >= 1.2.2"
requires "https://github.com/durability-labs/nim-nitro >= 0.7.2"
requires "https://github.com/durability-labs/nim-datastore >= 0.4.0"
requires "https://github.com/status-im/nim-presto >= 0.1.0"
requires "https://github.com/durability-labs/nim-circom-compat >= 0.1.3"
requires "https://github.com/durability-labs/nim-serde >= 2.1.0"
requires "https://github.com/durability-labs/nim-leopard >= 0.2.1"
requires "https://github.com/guzba/zippy >= 0.10.16"
requires "https://github.com/durability-labs/nim-chronicles#version-0-12-3-pre" # TODO: update to version 0.12.3 once it is released
requires "https://github.com/durability-labs/nim-groth16 >= 0.1.0"
requires "https://github.com/durability-labs/circom-witnessgen >= 0.1.3"

import std/os

task test, "Run node tests":
  exec "nimble c tests" / "testNode"
  exec "tests" / "testNode".toExe

task testContracts, "Run contract tests":
  exec "nimble c tests" / "testContracts"
  exec "tests" / "testContracts".toExe

task testIntegration, "Run integration tests":
  exec "nimble c" &
    " --define:archivist_system_testing_options" &
    " --out:build" / "integration-test" / "archivist-for-testing".toExe &
    " archivist"
  exec "nimble c tests" / "testIntegration"
  exec "tests" / "testIntegration".toExe

task testTools, "Run circuit downloader tests":
  exec "nimble build"
  exec "nimble c tests" / "testTools"
  exec "tests" / "testTools".toExe

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
