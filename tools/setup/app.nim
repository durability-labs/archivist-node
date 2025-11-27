import pkg/chronicles
import pkg/questionable
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

proc createNewEthKeyfile*(app: App, filename: string) =
  info "create a new key file here", filename

proc writeLinesToFile(app: App) =
  let f = open("config.toml", fmWrite)
  defer: f.close()

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

