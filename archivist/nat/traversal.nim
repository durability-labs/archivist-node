import std/tables
import pkg/questionable
import pkg/questionable/results
import pkg/chronos
import pkg/chronos/threadsync
import pkg/taskpools
import pkg/libp2p/multiaddress
import pkg/chronicles
import ../errors
import ./config
import ./portmapping

logScope:
  topics = "nat"

type
  NatTraversal* = ref object
    portmapping: PortMapping
    callbacks: Table[seq[MultiAddress], OnPortsMapped]
    mappings: Table[seq[MultiAddress], seq[MultiAddress]]
    taskpool: TaskPool
    renewing: Future[void].Raising([])

  OnPortsMapped* = proc(addresses: seq[MultiAddress]) {.gcsafe, raises: [].}

proc new*(_: type NatTraversal, config: NatConfig, taskpool: TaskPool): ?!NatTraversal =
  let portmapping = ?PortMapping.init(config)
  success NatTraversal(portmapping: portmapping, taskpool: taskpool)

proc renew(traversal: NatTraversal) {.async: (raises: []).}

proc start*(traversal: NatTraversal) {.async: (raises: [CancelledError]).} =
  traversal.renewing = traversal.renew()
  debug "started nat traversal"

proc stop*(traversal: NatTraversal) {.async: (raises: []).} =
  await traversal.renewing.cancelAndWait()
  debug "stopped nat traversal"

proc mapTask(
    portmapping: ptr PortMapping,
    address: MultiAddress,
    signal: ThreadSignalPtr,
    result: ptr [?!MultiAddress],
) =
  trace "started port mapping background task", address
  result[] = portmapping[].map(address)
  trace "finished port mapping background task", address, result = result[]
  discard signal.fireSync()

proc map(
    traversal: NatTraversal, address: MultiAddress
): Future[?!MultiAddress] {.async: (raises: [CancelledError]).} =
  without signal =? ThreadSignalPtr.new():
    return failure "unable to create thread signal"
  let portmapping = addr traversal.portmapping
  var mapped: ?!MultiAddress
  trace "spawning port mapping background task", address
  traversal.taskpool.spawn mapTask(portmapping, address, signal, addr mapped)
  if error =? catchAsync(await signal.wait()).errorOption:
    discard signal.close()
    return failure error
  if error =? signal.close().errorOption:
    return failure error
  mapped

proc map(
    traversal: NatTraversal, addresses: seq[MultiAddress]
): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
  for address in addresses:
    without mapped =? await traversal.map(address), error:
      warn "port mapping failed", address, error = error.msg
      continue
    if mapped notin result:
      result.add(mapped)

proc map(
    traversal: NatTraversal, addresses: seq[MultiAddress], callback: OnPortsMapped
) {.async: (raises: [CancelledError]).} =
  debug "mapping ports", addresses
  let mapped = await traversal.map(addresses)
  debug "mapping ports done", addresses, mapped
  if not (previous =? traversal.mappings .? [addresses]) or previous != mapped:
    trace "port mappings changed, notifying callback"
    traversal.mappings[addresses] = mapped
    callback(mapped)
  else:
    trace "port mappings remain unchanged"

proc mapPorts*(
    traversal: NatTraversal, addresses: seq[MultiAddress], callback: OnPortsMapped
) {.async: (raises: [CancelledError]).} =
  await traversal.map(addresses, callback)
  traversal.callbacks[addresses] = callback

proc renew(traversal: NatTraversal) {.async: (raises: []).} =
  try:
    while true:
      let interval = traversal.portmapping.portMappingLifetime div 3
      trace "waiting before renewing port mappings", interval
      await sleepAsync(interval)
      trace "renewing port mappings"
      for (addresses, callback) in traversal.callbacks.pairs:
        trace "renewing port mappings", addresses
        await traversal.map(addresses, callback)
      trace "finished renewing port mappings"
  except CancelledError:
    debug "port mapping renewal stopped"
    discard
