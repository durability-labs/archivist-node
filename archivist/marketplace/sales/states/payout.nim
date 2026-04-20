import ../../../logutils
import ../../../marketplace/abstractmarketplace
import ../../../utils/exceptions
import ../statemachine
import ../salesagent
import ./cancelled
import ./failed
import ./finished
import ./types

logScope:
  topics = "marketplace sales payout"

type SalePayout* = ref object of SaleState

method `$`*(state: SalePayout): string =
  "SalePayout"

method onCancelled*(state: SalePayout, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SalePayout, request: StorageRequest): ?State =
  return some State(SaleFailed())

method run*(
    state: SalePayout, machine: Machine
): Future[?State] {.async: (raises: []).} =
  let data = SalesAgent(machine).data
  let marketplace = SalesAgent(machine).context.marketplace

  try:
    let currentCollateral = await marketplace.currentCollateral(slot.id)
    debug "Collecting finished slot's reward", slotId = data.slotInfo.slotId
    await marketplace.freeSlot(data.slotInfo.slotId)

    return some State(SaleFinished(returnedCollateral: some currentCollateral))
  except CancelledError as e:
    trace "SalePayout.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SalePayout.run", error = e.msgDetail
    return some State(SaleErrored(error: e))
