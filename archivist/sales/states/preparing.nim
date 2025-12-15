import pkg/questionable
import pkg/questionable/results
import pkg/metrics

import ../../logutils
import ../../marketplace/abstractmarketplace
import ../../marketplace/storageinterface
import ../../utils/exceptions
import ../salesagent
import ../statemachine
import ./cancelled
import ./failed
import ./filled
import ./ignored
import ./slotreserving
import ./errored

type SalePreparing* = ref object of SaleState

logScope:
  topics = "marketplace sales preparing"

method `$`*(state: SalePreparing): string =
  "SalePreparing"

method onCancelled*(state: SalePreparing, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SalePreparing, request: StorageRequest): ?State =
  return some State(SaleFailed())

method onSlotFilled*(
    state: SalePreparing, requestId: RequestId, slotIndex: uint64
): ?State =
  return some State(SaleFilled())

method run*(
    state: SalePreparing, machine: Machine
): Future[?State] {.async: (raises: []).} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let context = agent.context
  let marketplace = context.marketplace

  try:
    await agent.retrieveRequest()
    await agent.subscribe()

    without request =? data.request:
      error "request could not be retrieved", id = data.requestId
      let error = newException(SaleError, "request could not be retrieved")
      return some State(SaleErrored(error: error))

    let slotId = slotId(data.requestId, data.slotIndex)
    let state = await marketplace.slotState(slotId)
    if state != SlotState.Free and state != SlotState.Repair:
      return some State(SaleIgnored(reprocessSlot: false))

    # TODO: Once implemented, check to ensure the host is allowed to fill the slot,
    # due to the [sliding window mechanism](https://github.com/logos-storage/codex-research/blob/master/design/marketplace.md#dispersal)

    logScope:
      slotIndex = data.slotIndex
      slotSize = request.ask.slotSize
      duration = request.ask.duration
      pricePerBytePerSecond = request.ask.pricePerBytePerSecond
      collateralPerByte = request.ask.collateralPerByte

    let requestEnd = await marketplace.getRequestEnd(data.requestId)
    let ask = request.ask

    var match = true
    match = match and terms =? context.availabilityTerms
    match = match and ask.slotSize <= context.storage.available
    match = match and ask.duration <= terms.maximumDuration
    match = match and ask.pricePerBytePerSecond >= terms.minimumPricePerBytePerSecond
    match = match and ask.collateralPerByte <= terms.maximumCollateralPerByte
    match = match and (not (until =? terms.availableUntil) or requestEnd <= until)
    if not match:
      debug "No availability found for request, ignoring"
      return some State(SaleIgnored(reprocessSlot: true))

    return some State(SaleSlotReserving())
  except CancelledError as e:
    trace "SalePreparing.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SalePreparing.run", error = e.msgDetail
    return some State(SaleErrored(error: e))
