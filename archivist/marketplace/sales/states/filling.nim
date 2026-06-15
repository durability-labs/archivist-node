import pkg/questionable/results

import ../../../logutils
import ../../../utils/exceptions
import ../../abstractmarketplace
import ../../storageinterface
import ../statemachine
import ../salesagent
import ./filled
import ./cancelled
import ./failed
import ./ignored
import ./types

logScope:
  topics = "marketplace sales filling"

type SaleFilling* = ref object of SaleState
  proof*: Groth16Proof

method `$`*(state: SaleFilling): string =
  "SaleFilling"

method onCancelled*(state: SaleFilling, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleFilling, request: StorageRequest): ?State =
  return some State(SaleFailed())

method run*(
    state: SaleFilling, machine: Machine
): Future[?State] {.async: (raises: []).} =
  let data = SalesAgent(machine).data
  let marketplace = SalesAgent(machine).context.marketplace
  let storage = SalesAgent(machine).context.storage

  logScope:
    slot = data.slotInfo

  without slot =? data.slotInfo.slot:
    raiseAssert "slot not set"

  let collateral = slot.request.ask.collateralPerSlot()
  try:
    debug "Filling slot"
    try:
      await marketplace.fillSlot(
        slot.request.id, slot.slotIndex, state.proof, collateral
      )
    except MarketplaceError as e:
      return some State(SaleErrored(error: e))

    return some State(SaleFilled())
  except CancelledError as e:
    trace "SaleFilling.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SaleFilling.run", error = e.msgDetail
    return some State(SaleErrored(error: e))
