import std/net
import std/strutils
import pkg/nat_traversal/miniupnpc
import pkg/libp2p/multiaddress
import pkg/chronos
import pkg/questionable/results

proc discoverGateways*(upnp: Miniupnp, timeout: Duration): ?!void =
  upnp.discoverDelay = timeout.seconds.cint
  if error =? upnp.discover().errorOption:
    return failure $error
  success()

proc selectGateway*(upnp: Miniupnp): ?!void =
  case upnp.selectIGD()
  of IGDNotFound:
    failure "Gateway device not found"
  of IGDFound, IGDNotConnected, NotAnIGD, IGDIpNotRoutable:
    success()

proc requestExternalIp*(upnp: Miniupnp): ?!IpAddress =
  let reslt = upnp.externalIPAddress()
  without value =? reslt:
    return failure $(reslt.error)
  without ip =? parseIpAddress($value).catch, error:
    return failure error.msg
  success ip

func toUpnpProtocol(protocol: IpTransportProtocol): UPNPProtocol =
  case protocol
  of IpTransportProtocol.tcpProtocol: UPNPProtocol.TCP
  of IpTransportProtocol.udpProtocol: UPNPProtocol.UDP

proc addPortMapping*(
    upnp: Miniupnp,
    external: Port,
    internal: Port,
    protocol: IpTransportProtocol,
    duration: Duration,
    description: string,
): ?!Port =
  let attempt1 = upnp.addPortMapping(
    externalPort = $external,
    protocol = protocol.toUpnpProtocol,
    internalHost = upnp.lanAddr,
    internalPort = $internal,
    desc = description,
    leaseDuration = duration.seconds,
  )
  if succeeded =? attempt1 and succeeded:
    return success external
  let attempt2 = upnp.addAnyPortMapping(
    externalPort = $external,
    protocol = protocol.toUpnpProtocol,
    internalHost = upnp.lanAddr,
    internalPort = $internal,
    desc = description,
    leaseDuration = duration.seconds,
  )
  without externalPortString =? attempt2:
    return failure $(attempt2.error)
  without externalPort =? parseInt(externalPortString).catch:
    return failure "received invalid external port: " & externalPortString
  return success Port(externalPort)
