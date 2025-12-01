import std/os
import std/httpclient
import pkg/chronicles
import pkg/questionable
import pkg/ethers
import ./networkconfig

type
  App* = ref object
    configLines: seq[string]
    networkConfig: ?ArchivistNetwork

proc writeConfigLine*(app: App, line: string) =
  app.configLines.add(line)

proc fetchNetworkConfig*(app: App, network: string): ArchivistNetwork =
  if isNone(app.networkConfig):
    info "Fetching network information...", network
    app.networkConfig = some getNetworkConfig(network)
  return !app.networkConfig

proc fetchPublicIp*(app: App): string =
  let
    url = "http://ip.archivist.storage"
    client = newHttpClient()
  try:
    info "Fetching public IP...", url
    return client.getContent(url)
  finally:
    client.close()

proc createNewEthKeyfile*(app: App, filename: string) =
  info "Generating Ethereum private key...", filename
  var rng = keys.newRng()[]
  let
    privKey = PrivateKey.random(rng)
    keyStr = $privKey

  if fileExists(filename):
    removeFile(filename)

  let f = open(filename, fmWrite)
  f.writeLine("0x" & keyStr)
  f.close()

proc runCircuitDownloader*(app: App) =
  info "run cirdl here!"

proc writeLinesToFile(app: App) =
  let filename = "config.toml"
  if fileExists(filename):
    removeFile(filename)

  let f = open(filename, fmWrite)
  defer: f.close()

  f.writeLine("# Archivist configuration file")
  f.writeLine("# created using setup executable")
  f.writeLine("")
  for line in app.configLines:
    f.writeLine(line)

proc finalize*(app: App) =
  app.writeLinesToFile()


# !! get config.json
# !! write to toml 
# !! write to localdir new key
# !! call cirdl  [circuitPath from boring config] [rpcEndpoint from config.json] ([marketplaceAddress])
# !! ping ip.archivist (known address)
# !! open browser (know address)

