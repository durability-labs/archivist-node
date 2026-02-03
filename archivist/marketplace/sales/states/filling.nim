import ../../../logutils
import ../../../utils/exceptions
import ../../abstractmarketplace
import ../statemachine
import ../salesagent
import ./filled
import ./cancelled
import ./failed
import ./ignored
import ./errored

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

  without (request =? data.request):
    raiseAssert "Request not set"

  logScope:
    requestId = data.requestId
    slotIndex = data.slotIndex

  let collateral = request.ask.collateralPerSlot()
  try:
    debug "Filling slot"
    try:
      await marketplace.fillSlot(
        data.requestId, data.slotIndex, state.proof, collateral
      )
    except SlotStateMismatchError:
      debug "Slot is already filled, ignoring slot"
      return some State(SaleIgnored(reprocessSlot: false, returnsCollateral: true))
    except MarketplaceError as e:
      return some State(SaleErrored(error: e))

    return some State(SaleFilled())
  except CancelledError as e:
    trace "SaleFilling.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SaleFilling.run", error = e.msgDetail
    return some State(SaleErrored(error: e))
