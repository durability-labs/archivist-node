import std/net
import pkg/questionable
import pkg/libp2p/multiaddress
import ./multiaddress

func discoveryAddresses*(
    announceAddresses: seq[MultiAddress], discoveryPort: Port
): seq[MultiAddress] =
  for announceAddress in announceAddresses:
    if ip =? announceAddress.ip:
      let protocol = IpTransportProtocol.udpProtocol
      let port = discoveryPort
      let discoveryAddress = MultiAddress.init(ip, protocol, port)
      if discoveryAddress notin result:
        result.add(discoveryAddress)
