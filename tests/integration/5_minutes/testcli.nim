import std/os
import std/tempfiles
import pkg/asynctest/chronos/unittest2
import pkg/stew/io2
import ../../testbed

suite "Command line interface":
  var testbed: Testbed

  setup:
    testbed = await Testbed.start()
    discard await testbed.hardhat.start()

  teardown:
    await testbed.stop()

  test "complains when persistence is enabled without ethereum private key":
    let expectedOutput = "Persistence enabled, but no Ethereum private key was set"
    discard await testbed.node
    .persistence()
    .noEthPrivateKey()
    .waitForOutput(expectedOutput)
    .start()

  test "complains when ethereum private key file has wrong permissions":
    let key = "4242424242424242424242424242424242424242424242424242424242424242"
    let unsafeKeyFile = genTempPath("", "")
    writeFile(unsafeKeyFile, key)
    setPermissions(unsafeKeyFile, 0o666).tryGet()
    let expectedOutput = "Ethereum private key file does not have safe file permissions"
    discard await testbed.node
    .persistence()
    .ethPrivateKey(unsafeKeyFile)
    .waitForOutput(expectedOutput)
    .start()

  test "suggests downloading of circuit files when there's no r1cs file":
    let expectedOutput =
      "Proving circuit files are not found. " &
      "Please run the following to download them:"
    discard await testbed.node
    .provider()
    .noCircomR1cs()
    .availability(false)
    .waitForOutput(expectedOutput)
    .start()

  test "suggests downloading of circuit files when there's no wasm file for the circom prover backend":
    let expectedOutput =
      "Proving circuit files are not found. " &
      "Please run the following to download them:"
    discard await testbed.node
    .provider()
    .proverBackend("circomcompat")
    .noCircomWasm()
    .availability(false)
    .waitForOutput(expectedOutput)
    .start()

  test "suggests downloading of circuit files when there's no zkey file":
    let expectedOutput =
      "Proving circuit files are not found. " &
      "Please run the following to download them:"
    discard await testbed.node
    .provider()
    .noCircomZkey()
    .availability(false)
    .waitForOutput(expectedOutput)
    .start()

  test "suggests downloading of circuit files when there's no graph file":
    let expectedOutput =
      "Proving circuit files are not found. " &
      "Please run the following to download them:"
    discard await testbed.node
    .provider()
    .noCircomGraph()
    .availability(false)
    .waitForOutput(expectedOutput)
    .start()

  test "warns about invalid marketplace address":
    discard await testbed.node
    .persistence()
    .marketplaceAddress("0xDEADDEADDEADDEADDEADDEADDEADDEADDEADDEAD")
    .waitForOutput("Unable to start marketplace")
    .start()

  test "automatically uses local config.toml":
    let
      expectedOutput = "Persistence enabled, but no Ethereum account was set"
      configFile = "config.toml"
      content = "persistence=true"

    writeFile(configFile, content)
    defer:
      osfiles.removeFile(configFile)

    discard await testbed.node.waitForOutput(expectedOutput).start()
