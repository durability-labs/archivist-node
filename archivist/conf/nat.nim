import std/strutils
import std/net
import pkg/questionable
import pkg/questionable/results
import ../nat/config

export config.NatConfig
export config.upnp
export config.pmp
export config.externalIp
export config.anyStrategy
export config.noNat

{.push raises: [].}

func parseNatConfig*(config: string): ?!NatConfig =
  let parts = config.split(":", 1)
  let strategy = parts[0]
  var address: ?IpAddress
  if argument =? parts .? [1]:
    without parsed =? parseIpAddress(argument).catch:
      return failure "Not a valid IP address: " & argument
    address = some parsed
  case strategy
  of "any":
    success NatConfig.anyStrategy(gateway = address)
  of "none":
    success NatConfig.noNat()
  of "upnp":
    success NatConfig.upnp()
  of "pmp":
    success NatConfig.pmp(gateway = address)
  of "extip":
    if ip =? address:
      success NatConfig.externalIp(ip)
    else:
      failure "Missing external IP address"
  else:
    failure "Not a valid NAT option: " & config
