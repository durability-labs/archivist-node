import std/tables
import pkg/questionable
import pkg/questionable/results
import pkg/chronos
import pkg/chronos/threadsync
import pkg/taskpools
import pkg/libp2p/multiaddress
import ../errors
import ./config
import ./portmapping

type
  NatTraversal* = ref object
    portmapping: PortMapping
    callbacks: Table[seq[MultiAddress], OnPortsMapped]
    mappings: Table[seq[MultiAddress], seq[MultiAddress]]
    taskpool: TaskPool
    renewing: Future[void].Raising([])

  OnPortsMapped* = proc(addresses: seq[MultiAddress]) {.gcsafe, raises: [].}

proc new*(_: type NatTraversal, config: NatConfig, taskpool: TaskPool): ?!NatTraversal =
  success NatTraversal(portmapping: ?PortMapping.init(config), taskpool: taskpool)

proc renew(traversal: NatTraversal) {.async: (raises: []).}

proc start*(traversal: NatTraversal) {.async: (raises: [CancelledError]).} =
  traversal.renewing = traversal.renew()

proc stop*(traversal: NatTraversal) {.async: (raises: []).} =
  await traversal.renewing.cancelAndWait()
  traversal.taskPool.shutdown()

proc mapTask(
    portmapping: ptr PortMapping,
    address: MultiAddress,
    signal: ThreadSignalPtr,
    result: ptr [?!MultiAddress],
) =
  result[] = portmapping[].map(address)
  discard signal.fireSync()

proc map(
    traversal: NatTraversal, address: MultiAddress
): Future[?!MultiAddress] {.async: (raises: [CancelledError]).} =
  without signal =? ThreadSignalPtr.new():
    return failure "unable to create thread signal"
  let portmapping = addr traversal.portmapping
  var mapped: ?!MultiAddress
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
    if mapped =? await traversal.map(address):
      result.add(mapped)

proc map*(
    traversal: NatTraversal, addresses: seq[MultiAddress], callback: OnPortsMapped
) {.async: (raises: [CancelledError]).} =
  let mapped = await traversal.map(addresses)
  if not (previous =? traversal.mappings .? [addresses]) or previous != mapped:
    traversal.mappings[addresses] = mapped
    callback(mapped)

proc renew(traversal: NatTraversal) {.async: (raises: []).} =
  try:
    while true:
      let interval = traversal.portmapping.portMappingLifetime div 3
      await sleepAsync(interval)
      for (addresses, callback) in traversal.callbacks.pairs:
        await traversal.map(addresses, callback)
  except CancelledError:
    discard
