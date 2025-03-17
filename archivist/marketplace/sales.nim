import std/sequtils
import pkg/questionable
import pkg/questionable/results
import pkg/stint
import pkg/datastore
import ../clock
import ../stores
import ../logutils
import ../utils/trackedfutures
import ../utils/exceptions
import ./abstractmarketplace
import ./availability/store
import ./availability/terms
import ./storageinterface
import ./contracts/requests
import ./contracts/marketplacecontract
import ./sales/salescontext
import ./sales/salesagent
import ./sales/statemachine
import ./sales/slotqueue
import ./sales/salesslot
import ./sales/states/preparing
import ./sales/states/unknown

## Sales holds a list of available storage that it may sell.
##
## When storage is requested on the marketplace that matches availability, the
## Sales object will instruct the node to persist the requested data. Once the
## data has been persisted, it uploads a proof of storage to the marketplace in
## an attempt to win a storage contract.
##
##    Node                        Sales                 Marketplace
##     |                          |                         |
##     | -- add availability  --> |                         |
##     |                          | <-- storage request --- |
##     | <----- store data ------ |                         |
##     | -----------------------> |                         |
##     |                          |                         |
##     | <----- prove data ----   |                         |
##     | -----------------------> |                         |
##     |                          | ---- storage proof ---> |

export stint
export salesagent
export salescontext

logScope:
  topics = "sales marketplace"

type Sales* = ref object
  context*: SalesContext
  agents*: seq[SalesAgent]
  running: bool
  availabilityStore: AvailabilityStore
  subscriptions: seq[abstractmarketplace.Subscription]
  trackedFutures: TrackedFutures

proc new*(
    _: type Sales,
    marketplace: AbstractMarketplace,
    clock: Clock,
    availability: AvailabilityStore,
    storage: StorageInterface,
): Sales =
  Sales(
    context: SalesContext(
      marketplace: marketplace,
      clock: clock,
      storage: storage,
      slotQueue: SlotQueue.new(),
    ),
    availabilityStore: availability,
    trackedFutures: TrackedFutures.new(),
    subscriptions: @[],
  )

proc remove(sales: Sales, agent: SalesAgent) {.async: (raises: []).} =
  await agent.stop()

  if sales.running:
    sales.agents.keepItIf(it != agent)

proc cleanUp(
    sales: Sales, agent: SalesAgent, reprocessSlot: bool, returnedCollateral: ?UInt256
) {.async: (raises: []).} =
  let data = agent.data

  logScope:
    topics = "sales cleanUp"
    requestId = data.requestId
    slotIndex = data.slotIndex

  trace "cleaning up sales agent"

  # Re-add items back into the queue to prevent small availabilities from
  # draining the queue. Seen items will be ordered last.
  if reprocessSlot and request =? data.request and var item =? agent.data.slotQueueItem:
    let queue = sales.context.slotQueue
    trace "pushing ignored item to queue"
    if err =? queue.push(item).errorOption:
      error "failed to readd slot to queue", errorType = $(type err), error = err.msg

  let fut = sales.remove(agent)
  sales.trackedFutures.track(fut)

proc processSlot(
    sales: Sales, item: SlotQueueItem
) {.async: (raises: [CancelledError]).} =
  debug "Processing slot from queue", requestId = item.requestId, slot = item.slotIndex

  let agent = newSalesAgent(
    sales.context, item.requestId, item.slotIndex, none StorageRequest, some item
  )

  let completed = newAsyncEvent()

  agent.onCleanUp = proc(
      reprocessSlot = false, returnedCollateral = UInt256.none
  ) {.async: (raises: []).} =
    trace "slot cleanup"
    await sales.cleanUp(agent, reprocessSlot, returnedCollateral)
    completed.fire()

  agent.onFilled = some proc(request: StorageRequest, slotIndex: uint64) =
    trace "slot filled"
    completed.fire()

  agent.start(SalePreparing())
  sales.agents.add agent

  trace "waiting for slot processing to complete"
  await completed.wait()
  trace "slot processing completed"

proc getSlots*(sales: Sales): Future[seq[Slot]] {.async.} =
  let marketplace = sales.context.marketplace
  let slotIds = await marketplace.mySlots()
  var slots: seq[Slot] = @[]

  info "Loading active slots", slotsCount = len(slots)
  for slotId in slotIds:
    if slot =? (await marketplace.getActiveSlot(slotId)):
      slots.add slot

  return slots

proc getSalesAgent(sales: Sales, slotId: SlotId): Future[?SalesAgent] {.async.} =
  for agent in sales.agents:
    if slotId(agent.data.requestId, agent.data.slotIndex) == slotId:
      return some agent

proc getSlot*(sales: Sales, slotId: SlotId): Future[?SalesSlot] {.async.} =
  without agent =? await sales.getSalesAgent(slotId):
    return none SalesSlot
  some SalesSlot.init(
    agent.data.requestId, agent.data.slotIndex, agent.data.request, agent.state
  )

proc load*(sales: Sales) {.async.} =
  let activeSlots = await sales.getSlots()

  for slot in activeSlots:
    let agent =
      newSalesAgent(sales.context, slot.request.id, slot.slotIndex, some slot.request)

    agent.onCleanUp = proc(
        reprocessSlot = false, returnedCollateral = UInt256.none
    ) {.async: (raises: []).} =
      await sales.cleanUp(agent, reprocessSlot, returnedCollateral)

    # There is no need to assign agent.onFilled as slots loaded from `mySlots`
    # are inherently already filled and so assigning agent.onFilled would be
    # superfluous.

    agent.start(SaleUnknown())
    sales.agents.add agent

proc onStorageRequested(
    sales: Sales, requestId: RequestId, ask: StorageAsk, expiry: uint64
) {.raises: [].} =
  logScope:
    topics = "marketplace sales onStorageRequested"
    requestId
    slots = ask.slots
    expiry

  let slotQueue = sales.context.slotQueue

  trace "storage requested, adding slots to queue"

  let collateral = ask.collateralPerSlot().stuint(256)

  without items =? SlotQueueItem.init(requestId, ask, expiry, collateral).catch, err:
    if err of SlotsOutOfRangeError:
      warn "Too many slots, cannot add to queue"
    else:
      warn "Failed to create slot queue items from request", error = err.msg
    return

  for item in items:
    # continue on failure
    if err =? slotQueue.push(item).errorOption:
      if err of SlotQueueItemExistsError:
        error "Failed to push item to queue becaue it already exists"
      elif err of QueueNotRunningError:
        warn "Failed to push item to queue becaue queue is not running"
      else:
        warn "Error adding request to SlotQueue", error = err.msg

proc onSlotFreed(sales: Sales, requestId: RequestId, slotIndex: uint64) =
  logScope:
    topics = "marketplace sales onSlotFreed"
    requestId
    slotIndex

  trace "slot freed, adding to queue"

  proc addSlotToQueue() {.async: (raises: []).} =
    let context = sales.context
    let marketplace = context.marketplace
    let queue = context.slotQueue

    try:
      without request =? (await marketplace.getRequest(requestId)), err:
        error "unknown request in contract", error = err.msgDetail
        return

      let collateral = request.ask.collateralPerSlot.stuint(256)
      let percentage = context.market.repairRewardPercentage
      let repairReward = (collateral * percentage.u256) div 100.u256

      if slotIndex > uint16.high.uint64:
        error "Cannot cast slot index to uint16, value = ", slotIndex
        return

      without slotQueueItem =?
        SlotQueueItem.init(request, slotIndex.uint16, collateral, repairReward).catch,
          err:
          warn "Too many slots, cannot add to queue", error = err.msgDetail
          return

      if err =? queue.push(slotQueueItem).errorOption:
        if err of SlotQueueItemExistsError:
          error "Failed to push item to queue because it already exists",
            error = err.msgDetail
        elif err of QueueNotRunningError:
          warn "Failed to push item to queue because queue is not running",
            error = err.msgDetail
    except CancelledError:
      trace "sales.addSlotToQueue was cancelled"

  # We could get rid of this by adding the storage ask in the SlotFreed event,
  # so we would not need to call getRequest to get the collateralPerSlot.
  let fut = addSlotToQueue()
  sales.trackedFutures.track(fut)

proc subscribeRequested(sales: Sales) {.async.} =
  let context = sales.context
  let marketplace = context.marketplace

  proc onStorageRequested(
      requestId: RequestId, ask: StorageAsk, expiry: uint64
  ) {.raises: [].} =
    sales.onStorageRequested(requestId, ask, expiry)

  try:
    let sub = await marketplace.subscribeRequests(onStorageRequested)
    sales.subscriptions.add(sub)
  except CancelledError as error:
    raise error
  except CatchableError as e:
    error "Unable to subscribe to storage request events", msg = e.msg

proc subscribeFulfilled*(sales: Sales) {.async.} =
  let context = sales.context
  let marketplace = context.marketplace
  let queue = context.slotQueue

  proc onFulfilled(requestId: RequestId) =
    trace "request fulfilled, removing all request slots from queue"
    queue.delete(requestId)

    for agent in sales.agents:
      agent.onFulfilled(requestId)

  try:
    let sub = await marketplace.subscribeFulfillment(onFulfilled)
    sales.subscriptions.add(sub)
  except CancelledError as error:
    raise error
  except CatchableError as e:
    error "Unable to subscribe to storage fulfilled events", msg = e.msg

proc subscribeFailure(sales: Sales) {.async.} =
  let context = sales.context
  let marketplace = context.marketplace
  let queue = context.slotQueue

  proc onFailed(requestId: RequestId) =
    trace "request failed, removing all request slots from queue"
    queue.delete(requestId)

    for agent in sales.agents:
      agent.onFailed(requestId)

  try:
    let sub = await marketplace.subscribeRequestFailed(onFailed)
    sales.subscriptions.add(sub)
  except CancelledError as error:
    raise error
  except CatchableError as e:
    error "Unable to subscribe to storage failure events", msg = e.msg

proc subscribeSlotFilled(sales: Sales) {.async.} =
  let context = sales.context
  let marketplace = context.marketplace
  let queue = context.slotQueue

  proc onSlotFilled(requestId: RequestId, slotIndex: uint64) =
    if slotIndex > uint16.high.uint64:
      error "Cannot cast slot index to uint16, value = ", slotIndex
      return

    trace "slot filled, removing from slot queue", requestId, slotIndex
    queue.delete(requestId, slotIndex.uint16)

    for agent in sales.agents:
      agent.onSlotFilled(requestId, slotIndex)

  try:
    let sub = await marketplace.subscribeSlotFilled(onSlotFilled)
    sales.subscriptions.add(sub)
  except CancelledError as error:
    raise error
  except CatchableError as e:
    error "Unable to subscribe to slot filled events", msg = e.msg

proc subscribeSlotFreed(sales: Sales) {.async.} =
  let context = sales.context
  let marketplace = context.marketplace

  proc onSlotFreed(requestId: RequestId, slotIndex: uint64) =
    sales.onSlotFreed(requestId, slotIndex)

  try:
    let sub = await marketplace.subscribeSlotFreed(onSlotFreed)
    sales.subscriptions.add(sub)
  except CancelledError as error:
    raise error
  except CatchableError as e:
    error "Unable to subscribe to slot freed events", msg = e.msg

proc subscribeSlotReservationsFull(sales: Sales) {.async.} =
  let context = sales.context
  let marketplace = context.marketplace
  let queue = context.slotQueue

  proc onSlotReservationsFull(requestId: RequestId, slotIndex: uint64) =
    if slotIndex > uint16.high.uint64:
      error "Cannot cast slot index to uint16, value = ", slotIndex
      return

    trace "reservations for slot full, removing from slot queue", requestId, slotIndex
    queue.delete(requestId, slotIndex.uint16)

  try:
    let sub = await marketplace.subscribeSlotReservationsFull(onSlotReservationsFull)
    sales.subscriptions.add(sub)
  except CancelledError as error:
    raise error
  except CatchableError as e:
    error "Unable to subscribe to slot filled events", msg = e.msg

proc startSlotQueue(sales: Sales) =
  let slotQueue = sales.context.slotQueue

  slotQueue.onProcessSlot = proc(
      item: SlotQueueItem
  ) {.async: (raises: [CancelledError]).} =
    trace "processing slot queue item", reqId = item.requestId, slotIdx = item.slotIndex
    await sales.processSlot(item)

  slotQueue.start()

proc availability*(sales: Sales): ?AvailabilityTerms =
  sales.context.availabilityTerms

proc updateAvailability*(
    sales: Sales, terms: AvailabilityTerms
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ?await sales.availabilityStore.save(terms)
  sales.context.availabilityTerms = some terms
  sales.context.slotQueue.availabilityChanged()
  success()

proc subscribe(sales: Sales) {.async.} =
  await sales.subscribeRequested()
  await sales.subscribeFulfilled()
  await sales.subscribeFailure()
  await sales.subscribeSlotFilled()
  await sales.subscribeSlotFreed()
  await sales.subscribeSlotReservationsFull()

proc unsubscribe(sales: Sales) {.async: (raises: []).} =
  for sub in sales.subscriptions:
    await sub.unsubscribe()

proc start*(sales: Sales): Future[?!void] {.async: (raises: [CancelledError]).} =
  try:
    sales.context.availabilityTerms = (await sales.availabilityStore.load()).toOption
    await sales.load()
    sales.startSlotQueue()
    await sales.subscribe()
    sales.running = true
    success()
  except CancelledError as error:
    raise error
  except CatchableError as error:
    failure error

proc stop*(sales: Sales) {.async: (raises: []).} =
  trace "stopping sales"
  sales.running = false
  await sales.context.slotQueue.stop()
  await noCancel sales.unsubscribe()
  await sales.trackedFutures.cancelTracked()

  for agent in sales.agents:
    await agent.stop()

  sales.agents = @[]

when defined(archivist_system_testing_options):
  func simulateProofFailures*(sales: Sales, every: int) =
    sales.context.simulateProofFailures = every
