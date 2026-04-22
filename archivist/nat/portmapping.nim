import std/net
import std/tables
import pkg/chronos
import pkg/libp2p/multiaddress
import pkg/questionable
import pkg/questionable/results
import pkg/nat_traversal/miniupnpc
import pkg/nat_traversal/natpmp
import pkg/chronicles
import ./config
import ./multiaddress
import ./pmp
import ./upnp

{.push raises: [].}

logScope:
  topics = "nat"

type PortMapping* = object
  config: NatConfig
  upnp: ?Miniupnp
  pmp: ?NatPmp
  externalPorts: Table[MultiAddress, Port]
  upnpDiscoverTimeout*: Duration = 200.milliseconds
  portMappingLifetime*: Duration = 1.hours
  portMappingDescription*: string = "archivist"

proc init*(_: type PortMapping, config: NatConfig): PortMapping =
  PortMapping(config: config)

proc mapExternalIp(mapping: PortMapping, address: MultiAddress): ?!MultiAddress =
  without protocol =? address.protocol and port =? address.port:
    return failure "Missing port in multiaddress"
  success MultiAddress.init(!mapping.config.externalIp, protocol, port)

proc mapRoutingTable(mapping: PortMapping, address: MultiAddress): ?!MultiAddress =
  without ip =? address.ip and port =? address.port:
    return failure "Missing IP address or port in multiaddress"
  let bindAddress = initTAddress(ip, port)
  if bindAddress.isGlobal and bindAddress.isUnicast:
    return success address
  let destination = initTAddress(static parseIpAddress("1.1.1.1"), Port(0))
  let route = getBestRoute(destination)
  if route.source.isGlobal and route.source.isUnicast:
    if source =? route.source.address.catch and protocol =? address.protocol:
      return success MultiAddress.init(source, protocol, port)
  failure "No routable IP address found, check your network connection"

proc mapPmp(mapping: var PortMapping, address: MultiAddress): ?!MultiAddress =
  without protocol =? address.protocol and internal =? address.port:
    return failure "Missing port in multiaddress"
  without var pmp =? mapping.pmp:
    pmp = ?NatPmp.new(mapping.config)
    mapping.pmp = some pmp
  without externalIp =? pmp.requestExternalIp(), error:
    return failure "NAT-PMP request external address failed: " & error.msg
  let lifetime = mapping.portMappingLifetime
  let external = mapping.externalPorts .? [address] |? internal
  without mapped =? pmp.addPortMapping(external, internal, protocol, lifetime), error:
    return failure "NAT-PMP port mapping failed: " & error.msg
  mapping.externalPorts[address] = mapped
  success MultiAddress.init(externalIp, protocol, mapped)

proc mapUpnp(mapping: var PortMapping, address: MultiAddress): ?!MultiAddress =
  without protocol =? address.protocol and internal =? address.port:
    return failure "Missing port in multiaddress"
  without var upnp =? mapping.upnp:
    upnp = Miniupnp.new()
    mapping.upnp = some upnp
  ?upnp.discoverGateways(mapping.upnpDiscoverTimeout)
  ?upnp.selectGateway()
  without externalIp =? upnp.requestExternalIp(), error:
    return failure "UPnP request external address failed: " & error.msg
  let lifetime = mapping.portMappingLifetime
  let external = mapping.externalPorts .? [address] |? internal
  let description = mapping.portMappingDescription
  let attempt = upnp.addPortMapping(external, internal, protocol, lifetime, description)
  without mapped =? attempt, error:
    return failure "UPnP port mapping failed: " & error.msg
  mapping.externalPorts[address] = mapped
  success MultiAddress.init(externalIp, protocol, mapped)

proc mapAny(mapping: var PortMapping, address: MultiAddress): ?!MultiAddress =
  let routingResult = mapping.mapRoutingTable(address)
  if mapped =? routingResult:
    mapping.config = NatConfig.noNat
    return success mapped

  let upnpResult = mapping.mapUpnp(address)
  if mapped =? upnpResult:
    mapping.config = NatConfig.upnp
    return success mapped

  let pmpResult = mapping.mapPmp(address)
  if mapped =? pmpResult:
    mapping.config = NatConfig.pmp(mapping.config.gateway)
    return success mapped

  debug "port mapping using routing table failed", error = routingResult.error.msg
  debug "port mapping using upnp failed", error = upnpResult.error.msg
  debug "port mapping using pmp failed", error = pmpResult.error.msg

  failure "UPnP/NAT-PMP failed"

proc map*(mapping: var PortMapping, address: MultiAddress): ?!MultiAddress =
  case mapping.config.strategy
  of NatStrategy.Any:
    mapping.mapAny(address)
  of NatStrategy.Upnp:
    mapping.mapUpnp(address)
  of NatStrategy.Pmp:
    mapping.mapPmp(address)
  of NatStrategy.ExternalIp:
    mapping.mapExternalIp(address)
  of NatStrategy.None:
    mapping.mapRoutingTable(address)
