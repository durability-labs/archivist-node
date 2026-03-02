import pkg/questionable
import pkg/questionable/results
import pkg/metrics

import ../../../logutils
import ../../../utils/exceptions
import ../../abstractmarketplace
import ../../storageinterface
import ../salesagent
import ../statemachine
import ./cancelled
import ./failed
import ./filled
import ./ignored
import ./slotreserving
import ./types

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
      requestId = data.requestId
      slotIndex = data.slotIndex
      slotSize = request.ask.slotSize
      duration = request.ask.duration
      pricePerBytePerSecond = request.ask.pricePerBytePerSecond
      collateralPerByte = request.ask.collateralPerByte

    let requestEnd = await marketplace.getRequestEnd(data.requestId)
    let ask = request.ask

    without terms =? context.availabilityTerms:
      debug "No availability terms set"
      return some State(SaleIgnored(reprocessSlot: true))

    var rejected = false
    if (ask.slotSize > context.storage.available):
      info "SlotSize larger than available storage"
      rejected = true

    if (ask.duration > terms.maximumDuration):
      info "Request duration longer than terms maximum"
      rejected = true

    if (ask.pricePerBytePerSecond < terms.minimumPricePerBytePerSecond):
      info "Request price lower than terms minimum"
      rejected = true

    if (ask.collateralPerByte > terms.maximumCollateralPerByte):
      info "Request collateral larger than terms maximum"
      rejected = true

    if (until =? terms.availableUntil and requestEnd > until):
      info "Request end time is after terms availableUntil"
      rejected = true

    if rejected:
      info "Slot sale rejected"
      return some State(SaleIgnored(reprocessSlot: true))

    return some State(SaleSlotReserving())
  except CancelledError as e:
    trace "SalePreparing.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SalePreparing.run", error = e.msgDetail
    return some State(SaleErrored(error: e))
