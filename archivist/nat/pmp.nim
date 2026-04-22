import std/net
import pkg/nat_traversal/natpmp
import pkg/libp2p/multiaddress
import pkg/chronos
import pkg/questionable/results
import ./config

{.push raises: [].}

proc new*(_: type NatPmp, config: NatConfig): ?!NatPmp =
  let pmp = newNatPmp()
  if gateway =? config.gateway:
    if error =? pmp.init(gateway).errorOption:
      return failure $error
  else:
    if error =? pmp.init().errorOption:
      return failure $error
  success pmp

proc requestExternalIp*(pmp: NatPmp): ?!IpAddress =
  let reslt = pmp.externalIPAddress()
  without value =? reslt:
    return failure reslt.error
  without ip =? parseIpAddress($value).catch, error:
    return failure error.msg
  success ip

func toNatPmpProtocol(protocol: IpTransportProtocol): NatPmpProtocol =
  case protocol
  of IpTransportProtocol.tcpProtocol: NatPmpProtocol.TCP
  of IpTransportProtocol.udpProtocol: NatPmpProtocol.UDP

proc addPortMapping*(
    pmp: NatPmp,
    external: Port,
    internal: Port,
    protocol: IpTransportProtocol,
    lifetime: Duration,
): ?!Port =
  let reslt = pmp.addPortMapping(
    eport = external.cushort,
    iport = internal.cushort,
    protocol = protocol.toNatPmpProtocol,
    lifetime = lifetime.seconds.cushort,
  )
  if reslt.isOk:
    {.hint[ConvFromXtoItselfNotNeeded]: off.}:
      success Port(reslt.value)
  else:
    Port.failure reslt.error
