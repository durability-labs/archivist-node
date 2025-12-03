{.push raises: [].}

import os
import strutils
import pkg/chronos
import pkg/chronicles
import pkg/questionable
import pkg/confutils/defs
import pkg/stew/io2
import pkg/ethers
import pkg/taskpools

import ../../conf
import ./backends
import ./prover

logScope:
  topics = "archivist slots proverfactory"

template graphFilePath(config: NodeConf): string =
  config.circuitDirPath / "proof_main.bin"

template r1csFilePath(config: NodeConf): string =
  config.circuitDirPath / "proof_main.r1cs"

template wasmFilePath(config: NodeConf): string =
  config.circuitDirPath / "proof_main.wasm"

template zkeyFilePath(config: NodeConf): string =
  config.circuitDirPath / "proof_main.zkey"

proc getGraphFile*(config: NodeConf): ?!string =
  if fileAccessible($config.circomGraph, {AccessFlags.Read}) and
      endsWith($config.circomGraph, ".bin"):
    success $config.circomGraph
  elif fileAccessible(config.graphFilePath, {AccessFlags.Read}) and
      endsWith(config.graphFilePath, ".bin"):
    success config.graphFilePath
  else:
    failure("Graph file not accessible or not found")

proc getR1csFile*(config: NodeConf): ?!string =
  if fileAccessible($config.circomR1cs, {AccessFlags.Read}) and
      endsWith($config.circomR1cs, ".r1cs"):
    success $config.circomR1cs
  elif fileAccessible(config.r1csFilePath, {AccessFlags.Read}) and
      endsWith(config.r1csFilePath, ".r1cs"):
    success config.r1csFilePath
  else:
    failure("R1CS file not accessible or not found")

proc getWasmFile*(config: NodeConf): ?!string =
  if fileAccessible($config.circomWasm, {AccessFlags.Read}) and
      endsWith($config.circomWasm, ".wasm"):
    success $config.circomWasm
  elif fileAccessible(config.wasmFilePath, {AccessFlags.Read}) and
      endsWith(config.wasmFilePath, ".wasm"):
    success config.wasmFilePath
  else:
    failure("WASM file not accessible or not found")

proc getZkeyFile*(config: NodeConf): ?!string =
  if fileAccessible($config.circomZkey, {AccessFlags.Read}) and
      endsWith($config.circomZkey, ".zkey"):
    success $config.circomZkey
  elif fileAccessible(config.zkeyFilePath, {AccessFlags.Read}) and
      endsWith(config.zkeyFilePath, ".zkey"):
    success config.zkeyFilePath
  else:
    failure("ZKey file not accessible or not found")

proc getMarketplaceAddressArgument(config: NodeConf): string =
  if address =? config.marketplaceAddress:
    return $address
  return ""

proc suggestDownloadTool(config: NodeConf) =
  let
    address = getMarketplaceAddressArgument(config)
    tokens = ["cirdl", "\"" & config.circuitDirPath & "\"", config.ethProvider, address]
    instructions = "'./" & tokens.join(" ") & "'"

  warn "Proving circuit files are not found. Please run the following to download them:",
    instructions

proc initializeNimGroth16Backend(
    config: NodeConf, tp: Taskpool
): ?!NimGroth16BackendRef =
  trace "Initializing NimGroth16 backend"

  let
    graphFile = ?getGraphFile(config)
    r1csFile = ?getR1csFile(config)
    zkeyFile = ?getZkeyFile(config)

  return NimGroth16BackendRef.new(
    $graphFile,
    $r1csFile,
    $zkeyFile,
    $config.curve,
    config.maxSlotDepth,
    config.maxDatasetDepth,
    config.maxBlockDepth,
    config.maxCellElms,
    config.numProofSamples,
    tp,
  )

proc initializeCircomCompatBackend(
    config: NodeConf, tp: Taskpool
): ?!CircomCompatBackendRef =
  trace "Initializing CircomCompat backend"

  let
    r1csFile = ?getR1csFile(config)
    wasmFile = ?getWasmFile(config)
    zkeyFile = ?getZkeyFile(config)

  return CircomCompatBackendRef.new(
    $r1csFile,
    $wasmFile,
    $zkeyFile,
    config.maxSlotDepth,
    config.maxDatasetDepth,
    config.maxBlockDepth,
    config.maxCellElms,
    config.numProofSamples,
  )

proc initializeProver*(config: NodeConf, tp: Taskpool): ?!Prover =
  let prover =
    case config.proverBackend
    of ProverBackendCmd.nimgroth16:
      without backend =? initializeNimGroth16Backend(config, tp), err:
        trace "Unable to initialize NimGroth16 backend: ", err = err.msg
        suggestDownloadTool(config)
        return failure(err)

      Prover.new(backend, config.numProofSamples, tp)
    of ProverBackendCmd.circomcompat:
      without backend =? initializeCircomCompatBackend(config, tp), err:
        trace "Unable to initialize CircomCompat backend: ", err = err.msg
        suggestDownloadTool(config)
        return failure(err)

      Prover.new(backend, config.numProofSamples, tp)

  success prover
