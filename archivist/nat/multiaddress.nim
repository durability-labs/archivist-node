import std/net
import pkg/libp2p/multiaddress
import pkg/libp2p/multicodec
import pkg/questionable
import pkg/questionable/results
import pkg/stew/endians2

{.push raises: [].}

proc ip4*(address: MultiAddress): ?IpAddress =
  if ip4 =? address[multiCodec("ip4")]:
    if bytes =? ip4.protoArgument and bytes.len == 4:
      var bytes4: array[4, byte]
      bytes4[0 ..^ 1] = bytes[0 ..^ 1]
      return some IpAddress(family: IPv4, address_v4: bytes4)
  none IpAddress

proc ip6*(address: MultiAddress): ?IpAddress =
  if ip6 =? address[multiCodec("ip6")]:
    if bytes =? ip6.protoArgument and bytes.len == 16:
      var bytes16: array[16, byte]
      bytes16[0 ..^ 1] = bytes[0 ..^ 1]
      return some IpAddress(family: IPv6, address_v6: bytes16)
  none IpAddress

proc ip*(address: MultiAddress): ?IpAddress =
  if ip =? address.ip4:
    some ip
  elif ip =? address.ip6:
    some ip
  else:
    none IpAddress

proc tcp*(address: MultiAddress): ?Port =
  if tcp =? address[multiCodec("tcp")]:
    if bytes =? tcp.protoArgument:
      return some Port(uint16.fromBytesBE(bytes))
  none Port

proc udp*(address: MultiAddress): ?Port =
  if udp =? address[multiCodec("udp")]:
    if bytes =? udp.protoArgument:
      return some Port(uint16.fromBytesBE(bytes))
  none Port

proc port*(address: MultiAddress): ?Port =
  if port =? address.tcp:
    some port
  elif port =? address.udp:
    some port
  else:
    none Port

proc protocol*(address: MultiAddress): ?IpTransportProtocol =
  if present =? (multiCodec("tcp") in address) and present:
    some IpTransportProtocol.tcpProtocol
  elif present =? (multiCodec("udp") in address) and present:
    some IpTransportProtocol.udpProtocol
  else:
    none IpTransportProtocol
