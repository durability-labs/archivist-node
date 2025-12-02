import std/os
import std/osproc
import std/httpclient
import std/strutils
import pkg/chronicles
import pkg/questionable
import pkg/ethers
import ./print
import ./networkconfig

type App* = ref object
  configLines: seq[string]
  networkConfig: ?ArchivistNetwork

  ethAddress: string
  # if we have networkConfig AND storage mode (not manual) is selected
  # then run CIRDL
  storageModeSelected*: bool
  # if testnet or devnet, display faucet links
  faucetLinkNetwork*: string
  # if set, display webui link
  webUi*: bool

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

proc saveFile(filename: string, content: string) =
  if fileExists(filename):
    removeFile(filename)

  let f = open(filename, fmWrite)
  f.writeLine(content)
  f.close()

proc createNewEthKeyfile*(app: App, privKeyFilename: string, addressFilename: string) =
  info "Generating Ethereum wallet...", privKeyFilename, addressFilename
  var rng = keys.newRng()[]
  let
    wallet = Wallet.createRandom()
    keyStr = "0x" & $(wallet.privateKey)
  app.ethAddress = $(wallet.address)

  saveFile(privKeyFilename, keyStr)
  saveFile(addressFilename, app.ethAddress)

proc findCirdl(): string =
  try:
    for file in walkDir(".", true):
      if file.path.startsWith("cirdl"):
        return file.path
  except Exception as exc:
    error "Exception while looking for 'cirdl' executable.", err = exc.msg
  raiseAssert "Failed to locate 'cirdl' executable."

proc runCircuitDownloader*(app: App) =
  info "Preparing to download zkProver circuit files..."
  let
    circuitDir = "circuitdir"
    rpcEndpoint = (!app.networkConfig).rpcs[0]
    cirdl = findCirdl()

  createDir(circuitDir)

  let value = execCmd(cirdl & " " & circuitDir & " " & rpcEndpoint)

  info "Circuit downloader completed", value

proc writeLinesToFile(app: App) =
  let filename = "config.toml"
  if fileExists(filename):
    removeFile(filename)

  let f = open(filename, fmWrite)
  defer:
    f.close()

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
  if app.ethAddress.len > 0:
    p2("Your Eth wallet address: " & app.ethAddress)
  p2("Use the following links to acquire tokens:")
  p3("Ethereum: " & ethLink)
  p3("TestTokens: " & tstLink)
  newline()

proc displayRunInstruction() =
  p1("You can start your Archivist node now by running the archivist executable.")
  p1("It will automatically detect and use the config file created by setup.")
  p1("For more information, run with '--help'")
  newline()

proc displayDocsLink() =
  p1("All the docs: http://docs.archivist.storage")
  newline()

proc displayWebUiLink() =
  p1("After your node has started, you can use the web-UI to operate it.")
  p2("Link: https://app.archivist.storage")
  newline()

proc finalize*(app: App) =
  app.writeLinesToFile()
  if isSome(app.networkConfig) and app.storageModeSelected:
    app.runCircuitDownloader()

  if app.faucetLinkNetwork.len > 0:
    app.displayFaucetLinks()

  displayRunInstruction()
  displayDocsLink()
  if app.webUi:
    displayWebUiLink()
