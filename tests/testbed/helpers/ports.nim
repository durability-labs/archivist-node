import std/net
import pkg/chronos

proc isPortFree*(address: IpAddress, port: Port): Future[bool] {.async.} =
  try:
    let address = initTAddress(address, port)
    let server = createStreamServer(address, {ReuseAddr})
    await server.closeWait()
    true
  except TransportOsError:
    false

proc findFreePort*(address: IpAddress, start: Port): Future[Port] {.async.} =
  result = start
  while not await isPortFree(address, result):
    inc result
