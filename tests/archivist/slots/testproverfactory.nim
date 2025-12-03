import os
import ../../asynctest

import pkg/chronos
import pkg/taskpools

import pkg/confutils/defs
import pkg/archivist/conf
import pkg/archivist/slots/proofs/backends
import pkg/archivist/slots/proofs/proverfactory {.all.}
import pkg/archivist/utils/natutils

import ../helpers
import ../examples

suite "Test BackendFactory":
  let circuitDir = "testecircuitdir"

  setup:
    createDir(circuitDir)

  teardown:
    removeDir(circuitDir)

  test "Should initialize with correct nimGroth16 config files":
    let config = NodeConf(
      cmd: StartUpCmd.persistence,
      nat: NatConfig(hasExtIp: false, nat: NatNone),
      metricsAddress: parseIpAddress("127.0.0.1"),
      persistenceCmd: PersistenceCmd.prover,
      marketplaceAddress: EthAddress.example.some,
      proverBackend: ProverBackendCmd.nimgroth16,
      circomGraph: InputFile("tests/circuits/fixtures/proof_main.bin"),
      circomR1cs: InputFile("tests/circuits/fixtures/proof_main.r1cs"),
      circomZkey: InputFile("tests/circuits/fixtures/proof_main.zkey"),
    )

    check:
      getGraphFile(config).tryGet == $config.circomGraph
      getR1csFile(config).tryGet == $config.circomR1cs
      getZkeyFile(config).tryGet == $config.circomZkey

  test "Should initialize with correct circom compat config files":
    let config = NodeConf(
      cmd: StartUpCmd.persistence,
      nat: NatConfig(hasExtIp: false, nat: NatNone),
      metricsAddress: parseIpAddress("127.0.0.1"),
      persistenceCmd: PersistenceCmd.prover,
      marketplaceAddress: EthAddress.example.some,
      proverBackend: ProverBackendCmd.circomcompat,
      circomWasm: InputFile("tests/circuits/fixtures/proof_main.wasm"),
      circomR1cs: InputFile("tests/circuits/fixtures/proof_main.r1cs"),
      circomZkey: InputFile("tests/circuits/fixtures/proof_main.zkey"),
    )

    check:
      getWasmFile(config).tryGet == $config.circomWasm
      getR1csFile(config).tryGet == $config.circomR1cs
      getZkeyFile(config).tryGet == $config.circomZkey

  test "Should initialize circom compat from local directory":
    let config = NodeConf(
      cmd: StartUpCmd.persistence,
      nat: NatConfig(hasExtIp: false, nat: NatNone),
      metricsAddress: parseIpAddress("127.0.0.1"),
      persistenceCmd: PersistenceCmd.prover,
      marketplaceAddress: EthAddress.example.some,
      proverBackend: ProverBackendCmd.circomcompat,
      # Set the circuitDir such that the tests/circuits/fixtures/ files
      # will be picked up as local files:
      circuitDir: OutDir("tests/circuits/fixtures"),
    )

    check:
      getR1csFile(config).tryGet == config.circuitDirPath / "proof_main.r1cs"
      getWasmFile(config).tryGet == config.circuitDirPath / "proof_main.wasm"
      getZkeyFile(config).tryGet == config.circuitDirPath / "proof_main.zkey"

  test "Should initialize nim groth16 from local directory":
    let config = NodeConf(
      cmd: StartUpCmd.persistence,
      nat: NatConfig(hasExtIp: false, nat: NatNone),
      metricsAddress: parseIpAddress("127.0.0.1"),
      persistenceCmd: PersistenceCmd.prover,
      marketplaceAddress: EthAddress.example.some,
      proverBackend: ProverBackendCmd.nimgroth16,
      # Set the circuitDir such that the tests/circuits/fixtures/ files
      # will be picked up as local files:
      circuitDir: OutDir("tests/circuits/fixtures"),
    )

    check:
      getGraphFile(config).tryGet == config.circuitDirPath / "proof_main.bin"
      getR1csFile(config).tryGet == config.circuitDirPath / "proof_main.r1cs"
      getZkeyFile(config).tryGet == config.circuitDirPath / "proof_main.zkey"

  test "Should suggest usage of downloader tool when files not available":
    let
      config = NodeConf(
        cmd: StartUpCmd.persistence,
        nat: NatConfig(hasExtIp: false, nat: NatNone),
        metricsAddress: parseIpAddress("127.0.0.1"),
        persistenceCmd: PersistenceCmd.prover,
        proverBackend: ProverBackendCmd.nimgroth16,
        marketplaceAddress: EthAddress.example.some,
        circuitDir: OutDir(circuitDir),
      )
      proverResult = config.initializeProver(Taskpool.new())

    check:
      proverResult.isErr
