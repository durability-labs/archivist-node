import pkg/questionable
import pkg/metrics

import ../../../logutils
import ../../../utils/exceptions
import ../../abstractmarketplace
import ../salesagent
import ../statemachine
import ./cancelled
import ./failed
import ./ignored
import ./downloading
import ./types

type SaleSlotReserving* = ref object of SaleState

logScope:
  topics = "marketplace sales reserving"

method `$`*(state: SaleSlotReserving): string =
  "SaleSlotReserving"

method onCancelled*(state: SaleSlotReserving, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleSlotReserving, request: StorageRequest): ?State =
  return some State(SaleFailed())

method run*(
    state: SaleSlotReserving, machine: Machine
): Future[?State] {.async: (raises: []).} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let context = agent.context
  let marketplace = context.marketplace

  without slot =? data.slotInfo.slot:
    raiseAssert "no sale slot"

  logScope:
    requestId = slot.request.id
    slotIndex = slot.slotIndex

  try:
    let canReserve = await marketplace.canReserveSlot(slot.request.id, slot.slotIndex)
    let collateral = slot.request.ask.collateralPerSlot()
    if canReserve and (await marketplace.tokensAvailable()) >= collateral.u256():
      try:
        trace "Reserving slot"
        await marketplace.reserveSlot(slot.request.id, slot.slotIndex)
      except SlotReservationNotAllowedError as e:
        debug "Slot cannot be reserved, ignoring", error = e.msg
        return some State(SaleIgnored(reprocessSlot: false))
      except MarketplaceError as e:
        return some State(SaleErrored(error: e))
      # other CatchableErrors are handled "automatically" by the SaleState

      trace "Slot successfully reserved"
      return some State(SaleDownloading())
    else:
      # do not re-add this slot to the queue, and return bytes from Reservation to
      # the Availability
      debug "Slot cannot be reserved, ignoring"
      return some State(SaleIgnored(reprocessSlot: false))
  except CancelledError as e:
    trace "SaleSlotReserving.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SaleSlotReserving.run", error = e.msgDetail
    return some State(SaleErrored(error: e))
