import std/net
import pkg/chronos

type Protocol* = enum
  Tcp
  Udp

proc isPortFree*(
    address: IpAddress, port: Port, protocol: Protocol
): Future[bool] {.async.} =
  try:
    let address = initTAddress(address, port)
    case protocol
    of Tcp:
      let server = createStreamServer(address, {ReuseAddr})
      await server.closeWait()
    of Udp:
      proc callback(_: DatagramTransport, _: TransportAddress) {.async: (raises: []).} =
        discard

      let server = newDatagramTransport(callback, local = address, flags = {ReuseAddr})
      await server.closeWait()
    true
  except TransportOsError:
    false

proc findFreePort*(
    address: IpAddress, start: Port, protocol = Tcp
): Future[Port] {.async.} =
  result = start
  while not await isPortFree(address, result, protocol):
    inc result
