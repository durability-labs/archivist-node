import std/envvars
import std/httpclient
import std/sequtils
import std/strutils

import pkg/chronicles
import pkg/serde/json
import pkg/questionable
import pkg/questionable/results

logScope:
  topics = "networkconfig"

proc getCompiledVersion(): string =
  return strip(staticExec("git tag"))

const compiledVersion* = "v0.1.0" # getCompiledVersion() - During development

# Endpoint types
type
  NetworkConfig* = object
    latest* {.serialize.}: string
    sprs* {.serialize.}: seq[ArchivistSprEntry]
    marketplace* {.serialize.}: seq[ArchivistMarketplaceEntry]

  ArchivistSprEntry* = object
    supportedVersions* {.serialize.}: seq[string]
    records* {.serialize.}: seq[string]

  ArchivistMarketplaceEntry* = object
    supportedVersions* {.serialize.}: seq[string]
    contractAddress* {.serialize.}: string

# Application types
type
  ArchivistNetwork* = object
    spr*: ArchivistSprEntry
    marketplace*: ArchivistMarketplaceEntry

# Connector
const EnvVarNetwork = "ARCHIVIST_NETWORK"
const EnvVarVersion = "ARCHIVIST_VERSION"
const EnvVarConfigUrl = "ARCHIVIST_CONFIG_URL"
const EnvVarConfigFile = "ARCHIVIST_CONFIG_FILE"

proc getEnvOrDefault(key: string, default: string): string =
  return getEnv(key, default)

proc fetchModelFromFile(file: string): string =
  trace "Loading model from file", file
  return readFile(file)

proc getFetchUrl(network: string): string =
  let overrideUrl = getEnvOrDefault(EnvVarConfigUrl, "")
  if overrideUrl.len > 0:
    return overrideUrl

  let network = getEnvOrDefault(EnvVarNetwork, network)
  return "http://config.archivist.storage/" & network & ".json"

proc fetchModelFromUrl(network: string): string =
  let
    url = getFetchUrl(network)
    client = newHttpClient()
  try:
    trace "Loading model form URL", url
    return client.getContent(url)
  finally:
    client.close()

proc fetchModelJson(network: string): string =
  let overrideFile = getEnvOrDefault(EnvVarConfigFile, "")
  if overrideFile.len > 0:
    return fetchModelFromFile(overrideFile)
  return fetchModelFromUrl(network)

proc fetchModel(network: string): NetworkConfig =
  let str = fetchModelJson(network)
  return tryGet(NetworkConfig.fromJson(str))

proc getCompiledNodeVersion(): string =
  if compiledVersion.isEmptyOrWhitespace:
    raiseAssert("Error: This application was not compiled from a versioned Archivist revision. " &
      "Unable to determine version information automatically. Please define '" & EnvVarVersion &
      "' and try again.")
  return compiledVersion

proc getVersion(fullModel: NetworkConfig): string =
  let selected = getEnvOrDefault(EnvVarVersion, "")
  if selected.len > 0:
    return selected
  return getCompiledNodeVersion()

proc mapToVersion(fullModel: NetworkConfig): ArchivistNetwork =
  let selected = getVersion(fullModel)
  info "Mapping to version", version=selected
  return ArchivistNetwork(
    spr: fullModel.sprs.filterIt(it.supportedVersions.contains(selected))[0],
    marketplace:
      fullModel.marketplace.filterIt(it.supportedVersions.contains(selected))[0]
  )

proc getNetworkConfig*(network: string): ArchivistNetwork =
  let fullModel = fetchModel(network)
  return mapToVersion(fullModel)
