import pkg/chronos
import ../../../logutils
import ../../../utils/exceptions
import ../../abstractmarketplace
import ../statemachine
import ../salesagent
import ./filled
import ./failed
import ./types
import ./proving
import ./cancelled
import ./payout

logScope:
  topics = "marketplace sales unknown"

type
  SaleUnknownError* = object of CatchableError
  UnexpectedSlotError* = object of SaleUnknownError

method `$`*(state: SaleUnknown): string =
  "SaleUnknown"

method onCancelled*(state: SaleUnknown, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleUnknown, request: StorageRequest): ?State =
  return some State(SaleFailed())

method run*(
    state: SaleUnknown, machine: Machine
): Future[?State] {.async: (raises: []).} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let marketplace = agent.context.marketplace

  try:
    await agent.retrieveSlot()

    if data.slotInfo.slot.isNone:
      error "slot could not be retrieved", slot = data.slotInfo
      let error = newException(SaleError, "slot could not be retrieved")
      return some State(SaleErrored(error: error))

    let slotState = await marketplace.slotState(data.slotInfo.slotId)

    case slotState
    of SlotState.Filled:
      return some State(SaleFilled())
    of SlotState.Finished:
      return some State(SalePayout())
    of SlotState.Failed:
      return some State(SaleFailed())
    of SlotState.Cancelled:
      return some State(SaleCancelled())
    of SlotState.Free:
      let message = "Slot state on chain should not be 'free'"
      let error = newException(UnexpectedSlotError, message)
      return some State(SaleErrored(error: error))
    of SlotState.Repair:
      let message = "Slot was forcible freed and host was removed from its hosting"
      let error = newException(SlotFreedError, message)
      return some State(SaleErrored(error: error))
  except CancelledError as e:
    trace "SaleUnknown.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SaleUnknown.run", error = e.msgDetail
    return some State(SaleErrored(error: e))
