## Custom TOML serialization for NodeConf
##
## This module provides a workaround for the TOML serialization library's
## limitation where it treats object types as nested objects instead of
## using custom writeValue procedures.
##
## The TOML library's writeValue procedure for objects automatically creates
## table headers (like [metricsAddress]) for object types, which produces
## malformed TOML. This custom serializer manually constructs the TOML
## string, ensuring that custom writeValue procedures are used.

{.push raises: [].}

import std/strutils
import std/options
import pkg/chronos
import pkg/toml_serialization
import pkg/libp2p
import ./conf
import ./logutils
import ./nat
import ./utils/natutils

proc toToml*(config: NodeConf): string =
  var toml = newStringOfCap(16384)
  
  proc append(key: string, value: string): string =
    result = key & " = " & value & "\n"
  
  proc appendOpt(key: string, value: Option[string]): string =
    if value.isSome:
      result = key & " = \"" & value.get() & "\"\n"
    else:
      result = ""
  
  proc appendOpt(key: string, value: Option[EthAddress]): string =
    if value.isSome:
      result = key & " = \"" & value.get().short0xHexLog & "\"\n"
    else:
      result = ""
  
  proc appendOpt(key: string, value: Option[int]): string =
    if value.isSome:
      result = key & " = " & $value.get() & "\n"
    else:
      result = ""
  
  proc multiAddrToString(ma: MultiAddress): string =
    ## Helper function to convert MultiAddress to string
    $ma
  
  # Simple string fields
  toml.add append("logLevel", "\"" & config.logLevel & "\"")
  toml.add append("logFormat", "\"" & $config.logFormat & "\"")
  toml.add append("agentString", "\"" & config.agentString & "\"")
  toml.add append("apiBindAddress", "\"" & config.apiBindAddress & "\"")
  toml.add append("netPrivKeyFile", "\"" & config.netPrivKeyFile & "\"")
  toml.add append("ethProvider", "\"" & config.ethProvider & "\"")
  
  # Boolean fields
  toml.add append("metricsEnabled", if config.metricsEnabled: "true" else: "false")
  toml.add append("persistence", if config.persistence: "true" else: "false")
  toml.add append("useSystemClock", if config.useSystemClock: "true" else: "false")
  toml.add append("validator", if config.validator: "true" else: "false")
  toml.add append("prover", if config.prover: "true" else: "false")
  toml.add append("circomNoZkey", if config.circomNoZkey: "true" else: "false")

  # Integer fields
  toml.add append("metricsPort", $int(config.metricsPort))
  toml.add append("discoveryPort", $int(config.discoveryPort))
  toml.add append("apiPort", $int(config.apiPort))
  toml.add append("maxPeers", $config.maxPeers)
  toml.add append("numThreads", $int(config.numThreads))
  toml.add append("blockMaintenanceNumberOfBlocks", $config.blockMaintenanceNumberOfBlocks)
  toml.add append("cacheSize", $int(config.cacheSize))
  toml.add append("validatorMaxSlots", $config.validatorMaxSlots)
  toml.add append("validatorGroupIndex", $config.validatorGroupIndex)
  toml.add append("marketplaceRequestCacheSize", $config.marketplaceRequestCacheSize)
  toml.add append("maxPriorityFeePerGas", $config.maxPriorityFeePerGas)
  toml.add append("numProofSamples", $config.numProofSamples)
  toml.add append("maxSlotDepth", $config.maxSlotDepth)
  toml.add append("maxDatasetDepth", $config.maxDatasetDepth)
  toml.add append("maxBlockDepth", $config.maxBlockDepth)
  toml.add append("maxCellElms", $config.maxCellElms)
  
  # Complex type fields (using string representations)
  toml.add append("metricsAddress", "\"" & $config.metricsAddress & "\"")
  toml.add append("dataDir", "\"" & string(config.dataDir) & "\"")
  toml.add append("circuitDir", "\"" & string(config.circuitDir) & "\"")
  
  # NatConfig - use custom serialization logic
  let natStr = if config.nat.hasExtIp:
    "extip:" & $config.nat.extIp
  else:
    case config.nat.nat
    of NatStrategy.NatAny: "any"
    of NatStrategy.NatNone: "none"
    of NatStrategy.NatUpnp: "upnp"
    of NatStrategy.NatPmp: "pmp"
  toml.add append("nat", "\"" & natStr & "\"")
  
  # Enum fields - need to be quoted as strings
  toml.add append("repoKind", "\"" & $config.repoKind & "\"")
  toml.add append("proverBackend", "\"" & $config.proverBackend & "\"")
  toml.add append("curve", "\"" & $config.curve & "\"")
  
  # Duration fields - use proper duration string representation
  proc formatDuration(d: Duration): string =
    let s = $d
    if s.len == 0: "0s" else: s
  
  toml.add append("blockTtl", "\"" & formatDuration(config.blockTtl) & "\"")
  toml.add append("blockMaintenanceInterval", "\"" & formatDuration(config.blockMaintenanceInterval) & "\"")
  
  # NBytes fields
  toml.add append("storageQuota", $int(config.storageQuota))
  
  # File path fields
  toml.add append("circomR1cs", "\"" & string(config.circomR1cs) & "\"")
  toml.add append("circomGraph", "\"" & string(config.circomGraph) & "\"")
  toml.add append("circomWasm", "\"" & string(config.circomWasm) & "\"")
  toml.add append("circomZkey", "\"" & string(config.circomZkey) & "\"")
  
  # Option fields
  toml.add appendOpt("apiCorsAllowedOrigin", config.apiCorsAllowedOrigin)
  toml.add appendOpt("logFile", config.logFile)
  toml.add appendOpt("ethPrivateKey", config.ethPrivateKey)
  toml.add appendOpt("marketplaceAddress", config.marketplaceAddress)
  toml.add appendOpt("validatorGroups", config.validatorGroups)
  
  # MultiAddress array
  if config.listenAddrs.len > 0:
    toml.add("listenAddrs = [\n")
    for la in config.listenAddrs:
      toml.add("  \"")
      toml.add(multiAddrToString(la))
      toml.add("\",\n")
    toml.add("]\n")
  
  # SignedPeerRecord array
  if config.bootstrapNodes.len > 0:
    toml.add("bootstrapNodes = [\n")
    for node in config.bootstrapNodes:
      toml.add("  \"")
      toml.add($node)  # SignedPeerRecord $ operator returns the string representation
      toml.add("\",\n")
    toml.add("]\n")
  
  result = toml

{.pop.}
