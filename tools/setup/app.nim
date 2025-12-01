import std/os
import std/osproc
import std/httpclient
import pkg/chronicles
import pkg/questionable
import pkg/ethers
import ./print
import ./networkconfig

type
  App* = ref object
    configLines: seq[string]
    networkConfig: ?ArchivistNetwork

    # if we have networkConfig AND storage mode (not manual) is selected
    # then run CIRDL
    storageModeSelected*: bool
    # if testnet or devnet, display faucet links
    faucetLinkNetwork*: string

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
  info "Preparing to download zkProver circuit files..."
  let
    circuitDir = "circuitdir"
    rpcEndpoint = (!app.networkConfig).rpcs[0]

  createDir(circuitDir)

  let value = execCmd("cirdl " & circuitDir & " " & rpcEndpoint)
  
  info "Circuit downloader completed", value

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

proc displayFaucetLinks(app: App) = 
  let
    ethLink = "http://faucet-arb." & app.faucetLinkNetwork & ".archivist.storage"
    tstLink = "http://faucet-tst." & app.faucetLinkNetwork & ".archivist.storage"

  newline()
  p2("Your ETH wallet address: todo :O")
  p2("Use the following links to acquire tokens:")
  p3("Ethereum: " & ethLink)
  p3("TestTokens: " & tstLink)
  newline()

proc displayDocsLinks(app: App) = 
  p1("All the docs: http://docs.archivist.storage")
  newline()

proc finalize*(app: App) =
  app.writeLinesToFile()
  if isSome(app.networkConfig) and app.storageModeSelected:
    app.runCircuitDownloader()

  if app.faucetLinkNetwork.len > 0:
    app.displayFaucetLinks()

  app.displayDocsLinks()

# !! get config.json
# !! write to toml 
# !! write to localdir new key
# !! call cirdl  [circuitPath from boring config] [rpcEndpoint from config.json] ([marketplaceAddress])
# !! ping ip.archivist (known address)
# !! open browser (know address)

