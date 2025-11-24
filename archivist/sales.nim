import std/sequtils
import std/sugar
import pkg/questionable
import pkg/questionable/results
import pkg/stint
import pkg/datastore
import ./marketplace/abstractmarketplace
import ./clock
import ./stores
import ./contracts/requests
import ./contracts/marketplacecontract
import ./logutils
import ./sales/salescontext
import ./sales/salesagent
import ./sales/statemachine
import ./sales/slotqueue
import ./sales/salesslot
import ./sales/states/preparing
import ./sales/states/unknown
import ./utils/trackedfutures
import ./utils/exceptions

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
export reservations
export salesagent
export salescontext

logScope:
  topics = "sales marketplace"

type Sales* = ref object
  context*: SalesContext
  agents*: seq[SalesAgent]
  running: bool
  subscriptions: seq[abstractmarketplace.Subscription]
  trackedFutures: TrackedFutures

proc `onStore=`*(sales: Sales, onStore: OnStore) =
  sales.context.onStore = some onStore

proc `onClear=`*(sales: Sales, onClear: OnClear) =
  sales.context.onClear = some onClear

proc `onSale=`*(sales: Sales, callback: OnSale) =
  sales.context.onSale = some callback

proc `onProve=`*(sales: Sales, callback: OnProve) =
  sales.context.onProve = some callback

proc `onExpiryUpdate=`*(sales: Sales, callback: OnExpiryUpdate) =
  sales.context.onExpiryUpdate = some callback

proc onStore*(sales: Sales): ?OnStore =
  sales.context.onStore

proc onClear*(sales: Sales): ?OnClear =
  sales.context.onClear

proc onSale*(sales: Sales): ?OnSale =
  sales.context.onSale

proc onProve*(sales: Sales): ?OnProve =
  sales.context.onProve

proc onExpiryUpdate*(sales: Sales): ?OnExpiryUpdate =
  sales.context.onExpiryUpdate

proc new*(
    _: type Sales, marketplace: AbstractMarketplace, clock: Clock, repo: RepoStore
): Sales =
  let reservations = Reservations.new(repo)
  Sales(
    context: SalesContext(
      marketplace: marketplace,
      clock: clock,
      reservations: reservations,
      slotQueue: SlotQueue.new(),
    ),
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
    reservationId = data.reservation .? id |? ReservationId.default
    availabilityId = data.reservation .? availabilityId |? AvailabilityId.default

  trace "cleaning up sales agent"

  # if reservation for the SalesAgent was not created, then it means
  # that the cleanUp was called before the sales process really started, so
  # there are not really any bytes to be returned
  if request =? data.request and reservation =? data.reservation:
    if returnErr =? (
      await noCancel sales.context.reservations.returnBytesToAvailability(
        reservation.availabilityId, reservation.id, request.ask.slotSize
      )
    ).errorOption:
      error "failure returning bytes",
        error = returnErr.msg, bytes = request.ask.slotSize

    # delete reservation and return reservation bytes back to the availability
    if reservation =? data.reservation and
        deleteErr =? (
          await noCancel sales.context.reservations.deleteReservation(
            reservation.id, reservation.availabilityId, returnedCollateral
          )
        ).errorOption:
      error "failure deleting reservation", error = deleteErr.msg

  # Re-add items back into the queue to prevent small availabilities from
  # draining the queue. Seen items will be ordered last.
  if reprocessSlot and request =? data.request and var item =? agent.data.slotQueueItem:
    let queue = sales.context.slotQueue
    trace "pushing ignored item to queue"
    if err =? queue.push(item).errorOption:
      error "failed to readd slot to queue", errorType = $(type err), error = err.msg

  let fut = sales.remove(agent)
  sales.trackedFutures.track(fut)

proc filled(sales: Sales, request: StorageRequest, slotIndex: uint64) =
  if onSale =? sales.context.onSale:
    onSale(request, slotIndex)

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
    sales.filled(request, slotIndex)
    completed.fire()

  agent.start(SalePreparing())
  sales.agents.add agent

  trace "waiting for slot processing to complete"
  await completed.wait()
  trace "slot processing completed"

proc deleteInactiveReservations(sales: Sales, activeSlots: seq[Slot]) {.async.} =
  let reservations = sales.context.reservations
  without reservs =? await reservations.all(Reservation):
    return

  let unused = reservs.filter(
    r => (
      let slotId = slotId(r.requestId, r.slotIndex)
      not activeSlots.any(slot => slot.id == slotId)
    )
  )

  if unused.len == 0:
    return

  info "Found unused reservations for deletion", unused = unused.len

  for reservation in unused:
    logScope:
      reservationId = reservation.id
      availabilityId = reservation.availabilityId

    if err =? (
      await reservations.deleteReservation(reservation.id, reservation.availabilityId)
    ).errorOption:
      error "Failed to delete unused reservation", error = err.msg
    else:
      trace "Deleted unused reservation"

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

  await sales.deleteInactiveReservations(activeSlots)

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

proc OnAvailabilitySaved(
    sales: Sales, availability: Availability
) {.async: (raises: []).} =
  ## When availabilities are modified or added, the slot queue should be
  ## notified so that it can reprocess slots.
  sales.context.slotQueue.availabilitiesChanged()

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

  let marketplace = sales.context.marketplace

  without collateral =? marketplace.slotCollateral(
    ask.collateralPerSlot, SlotState.Free
  ), err:
    error "Request failure, unable to calculate collateral", error = err.msg
    return

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

      # Take the repairing state into consideration to calculate the collateral.
      # This is particularly needed because it will affect the priority in the queue
      # and we want to give the user the ability to tweak the parameters.
      # Adding the repairing state directly in the queue priority calculation
      # would not allow this flexibility.
      without collateral =?
        marketplace.slotCollateral(request.ask.collateralPerSlot, SlotState.Repair), err:
        error "Failed to add freed slot to queue: unable to calculate collateral",
          error = err.msg
        return

      if slotIndex > uint16.high.uint64:
        error "Cannot cast slot index to uint16, value = ", slotIndex
        return

      without slotQueueItem =?
        SlotQueueItem.init(request, slotIndex.uint16, collateral = collateral).catch,
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
    except CancelledError as e:
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

proc subscribeCancellation(sales: Sales) {.async.} =
  let context = sales.context
  let marketplace = context.marketplace
  let queue = context.slotQueue

  proc onCancelled(requestId: RequestId) =
    trace "request cancelled (via contract RequestCancelled event), removing all request slots from queue"
    queue.delete(requestId)

  try:
    let sub = await marketplace.subscribeRequestCancelled(onCancelled)
    sales.subscriptions.add(sub)
  except CancelledError as error:
    raise error
  except CatchableError as e:
    error "Unable to subscribe to cancellation events", msg = e.msg

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
  let reservations = sales.context.reservations

  slotQueue.onProcessSlot = proc(
      item: SlotQueueItem
  ) {.async: (raises: [CancelledError]).} =
    trace "processing slot queue item", reqId = item.requestId, slotIdx = item.slotIndex
    await sales.processSlot(item)

  slotQueue.start()

  proc OnAvailabilitySaved(availability: Availability) {.async: (raises: []).} =
    if availability.enabled:
      await sales.OnAvailabilitySaved(availability)

  reservations.OnAvailabilitySaved = OnAvailabilitySaved

proc subscribe(sales: Sales) {.async.} =
  await sales.subscribeRequested()
  await sales.subscribeFulfilled()
  await sales.subscribeFailure()
  await sales.subscribeSlotFilled()
  await sales.subscribeSlotFreed()
  await sales.subscribeCancellation()
  await sales.subscribeSlotReservationsFull()

proc unsubscribe(sales: Sales) {.async.} =
  for sub in sales.subscriptions:
    try:
      await sub.unsubscribe()
    except CancelledError as error:
      raise error
    except CatchableError as e:
      error "Unable to unsubscribe from subscription", error = e.msg

proc start*(sales: Sales) {.async.} =
  await sales.load()
  sales.startSlotQueue()
  await sales.subscribe()
  sales.running = true

proc stop*(sales: Sales) {.async.} =
  trace "stopping sales"
  sales.running = false
  await sales.context.slotQueue.stop()
  await sales.unsubscribe()
  await sales.trackedFutures.cancelTracked()

  for agent in sales.agents:
    await agent.stop()

  sales.agents = @[]
