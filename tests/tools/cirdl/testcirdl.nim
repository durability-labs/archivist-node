import std/os
import std/osproc
import pkg/chronos
import pkg/archivist/contracts
import ../../asynctest
import ../../testbed

suite "tools/cirdl":
  var testbed: Testbed
  var hardhat: Hardhat

  setup:
    testbed = await Testbed.start()
    hardhat = await testbed.hardhat.start()

  teardown:
    await testbed.stop()

  const
    cirdl = "build" / "tools" / "cirdl" / "cirdl"
    workdir = "."

  test "circuit download tool":
    let circuitPath = "testcircuitpath"

    discard existsOrCreateDir(circuitPath)

    let args = [circuitPath, hardhat.jsonRpcUrl]

    let process = osproc.startProcess(cirdl, workdir, args, options = {poParentStreams})

    let returnCode = process.waitForExit()
    check returnCode == 0

    check:
      fileExists(circuitPath / "proof_main_verification_key.json")
      fileExists(circuitPath / "proof_main.r1cs")
      fileExists(circuitPath / "proof_main.wasm")
      fileExists(circuitPath / "proof_main.zkey")

    removeDir(circuitPath)
