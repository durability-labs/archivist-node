import pkg/chronicles

type
  App* = ref object

proc writeConfigLine*(app: App, line: string) =
  info "writing config line", line

proc fetchNetworkConfig*(app: App, network: string) =
  info "fetch network object", network

proc createNewEthKeyfile*(app: App, filename: string) =
  info "create a new key file here", filename