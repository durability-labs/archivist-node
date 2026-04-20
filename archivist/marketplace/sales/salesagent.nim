import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/stint
import ../../errors
import ../../logutils
import ../../utils/exceptions
import ../../utils/exponentialbackoff
import ../contracts/requests
import ../abstractmarketplace
import ./statemachine
import ./salescontext
import ./salesdata
import ./slotinfo
import ./slotqueue

export slotinfo

logScope:
  topics = "marketplace sales"

type
  SalesAgent* = ref object of Machine
    context*: SalesContext
    data*: SalesData
    subscribed: bool
    # Slot-level callbacks.
    onCleanUp*: OnCleanUp
    onFilled*: ?OnFilled

  OnCleanUp* = proc(reprocessSlot = false) {.async: (raises: []).}
  OnFilled* = proc() {.gcsafe, raises: [].}

  SalesAgentError = object of ArchivistError
  AllSlotsFilledError* = object of SalesAgentError

func `==`*(a, b: SalesAgent): bool =
  a.data.slotInfo.slotId == b.data.slotInfo.slotId

proc newSalesAgent*(
    context: SalesContext,
    slotInfo: SlotInfo,
    slotQueueItem = SlotQueueItem.none,
    errorBackoff = ExponentialBackoff(),
): SalesAgent =
  let agent = SalesAgent.new()
  agent.context = context
  agent.data = SalesData(
    slotInfo: slotInfo,
    slotQueueItem: slotQueueItem,
    errorBackoff: errorBackoff
  )
  return agent

proc retrieveSlot*(agent: SalesAgent) {.async.} =
  let data = agent.data
  let marketplace = agent.context.marketplace
  if data.slotInfo.slot.isNone:
    if requestId =? data.slotInfo.requestId and data.slotInfo.slotIndex.isSome:
      if request =? await marketplace.getRequest(requestId):
        data.slotInfo.request = request
    else:
      if slot =? await marketplace.getActiveSlot(data.slotInfo.slotId):
        data.slotInfo.slot = slot

proc retrieveRequestState*(agent: SalesAgent): Future[?RequestState] {.async.} =
  let data = agent.data
  let marketplace = agent.context.marketplace
  without requestId =? data.slotInfo.requestId:
    return RequestState.none
  return await marketplace.requestState(requestId)

func state*(agent: SalesAgent): ?string =
  proc description(state: State): string =
    $state

  agent.query(description)

proc subscribeCancellation*(agent: SalesAgent) {.async.} =
  let data = agent.data
  let clock = agent.context.clock

  if data.cancelled != nil:
    return

  proc onCancelled() {.async: (raises: []).} =
    without slot =? data.slotInfo.slot:
      return

    try:
      let marketplace = agent.context.marketplace
      let expiry =
        (await marketplace.requestExpiresAt(slot.request.id)).toSecondsSince1970

      while true:
        let deadline = max(clock.now, expiry) + 1
        trace "Waiting for request to be cancelled", now = clock.now, expiry = deadline
        await clock.waitUntil(deadline)

        without state =? await agent.retrieveRequestState():
          error "Unknown request", requestId = slot.request.id
          return

        case state
        of New:
          discard
        of RequestState.Cancelled:
          agent.schedule(cancelledEvent(slot.request))
          break
        of RequestState.Started, RequestState.Finished, RequestState.Failed:
          break

        debug "The request is not yet canceled, even though it should be. Waiting for some more time.",
          currentState = state, now = clock.now

    except CancelledError:
      trace "Waiting for expiry to lapse was cancelled", requestId = slot.request.id
    except CatchableError as e:
      error "Error while waiting for expiry to lapse", error = e.msgDetail

  data.cancelled = onCancelled()

proc unsubscribeCancellation*(agent: SalesAgent) {.async: (raises: []).} =
  let data = agent.data
  if data.cancelled != nil:
    await data.cancelled.cancelAndWait()
    data.cancelled = nil

method onFulfilled*(
    agent: SalesAgent, requestId: RequestId
) {.base, gcsafe, raises: [].} =
  if myRequestId =? agent.data.slotInfo.requestId:
    if myRequestId == requestId:
      let cancelled = agent.data.cancelled
      if not cancelled.isNil and not cancelled.finished:
        cancelled.cancelSoon()

method onFailed*(agent: SalesAgent, requestId: RequestId) {.base, gcsafe, raises: [].} =
  if myRequest =? agent.data.slotInfo.request:
    if myRequest.id == requestId:
      agent.schedule(failedEvent(myRequest))

method onSlotFilled*(
    agent: SalesAgent, requestId: RequestId, slotIndex: uint64
) {.base, gcsafe, raises: [].} =
  let slotId = slotId(requestId, slotIndex)
  if agent.data.slotInfo.slotId == slotId:
    agent.schedule(slotFilledEvent(requestId, slotIndex))

proc stop*(agent: SalesAgent) {.async: (raises: []).} =
  await Machine(agent).stop()
  await agent.unsubscribeCancellation()
