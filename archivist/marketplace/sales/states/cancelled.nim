import ../../../logutils
import ../../../utils/exceptions
import ../../abstractmarketplace
import ../salesagent
import ../statemachine
import ./errored

logScope:
  topics = "marketplace sales cancelled"

type SaleCancelled* = ref object of SaleState

method `$`*(state: SaleCancelled): string =
  "SaleCancelled"

proc slotIsFilledByMe(
    marketplace: AbstractMarketplace, requestId: RequestId, slotIndex: uint64
): Future[bool] {.async: (raises: [CancelledError, MarketplaceError]).} =
  let host = await marketplace.getHost(requestId, slotIndex)
  let me = await marketplace.getSigner()

  return host == me.some

method run*(
    state: SaleCancelled, machine: Machine
): Future[?State] {.async: (raises: []).} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let marketplace = agent.context.marketplace

  without request =? data.request:
    raiseAssert "no sale request"

  try:
    var returnedCollateral = UInt256.none

    if await slotIsFilledByMe(marketplace, data.requestId, data.slotIndex):
      debug "Collecting collateral and partial payout",
        requestId = data.requestId, slotIndex = data.slotIndex

      let slot = Slot(request: request, slotIndex: data.slotIndex)
      let currentCollateral = await marketplace.currentCollateral(slot.id)

      try:
        await marketplace.freeSlot(slot.id)
      except SlotStateMismatchError as e:
        warn "Failed to free slot because slot is already free", error = e.msg

      returnedCollateral = currentCollateral.some

    if onCleanUp =? agent.onCleanUp:
      await onCleanUp(
        reprocessSlot = false,
        returnedCollateral = some currentCollateral.stuint(256),
      )

    warn "Sale cancelled due to timeout",
      requestId = data.requestId, slotIndex = data.slotIndex
  except CancelledError as e:
    trace "SaleCancelled.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SaleCancelled.run", error = e.msgDetail
    return some State(SaleErrored(error: e))
