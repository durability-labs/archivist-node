import std/tables
import pkg/questionable
import pkg/questionable/results
import pkg/chronos
import pkg/chronos/threadsync
import pkg/taskpools
import pkg/libp2p/multiaddress
import pkg/chronicles
import ../errors
import ../utils
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
    renewalInterval: Duration

  OnPortsMapped* = proc(addresses: seq[MultiAddress]) {.gcsafe, raises: [].}

proc new*(
    _: type NatTraversal,
    config: NatConfig,
    renewalInterval: Duration,
    taskpool: TaskPool,
): NatTraversal =
  let portmapping = PortMapping.init(config)
  NatTraversal(
    portmapping: portmapping, renewalInterval: renewalInterval, taskpool: taskpool
  )

proc renew(traversal: NatTraversal) {.async: (raises: []).}

proc start*(traversal: NatTraversal) {.async: (raises: [CancelledError]).} =
  traversal.renewing = traversal.renew()
  debug "started nat traversal"

proc stop*(traversal: NatTraversal) {.async: (raises: []).} =
  await traversal.renewing.cancelAndWait()
  debug "removing port mappings"
  if error =? traversal.portmapping.deleteMappings().errorOption:
    warn "removing port mappings failed", error = error.msg
  debug "stopped nat traversal"

proc mapTask(
    ctx: SharedPtr[TaskCtx[MultiAddress]],
    portmapping: ptr PortMapping,
    address: ptr MultiAddress,
) =
  defer:
    if err =? ctx[].signal.fireSync().errorOption:
      warn "Failed to fire port mapping completion signal", error = err

  trace "started port mapping background task", address = address[]
  ctx[].result = mapThreadSpawnErr(portmapping[].map(address[]))
  trace "finished port mapping background task", address = address[]

proc map(
    traversal: sink NatTraversal, address: sink MultiAddress
): Future[?!MultiAddress] {.async: (raises: [CancelledError]).} =
  trace "spawning port mapping background task", address
  await spawnJoin(
    proc(ctx: SharedPtr[TaskCtx[MultiAddress]]) {.gcsafe, raises: [].} =
      traversal.taskpool.spawn mapTask(ctx, addr traversal.portmapping, addr address)
  )

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
      let interval = traversal.renewalInterval
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
