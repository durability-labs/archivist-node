import ../../../logutils
import ../../../utils/exceptions
import ../../abstractmarketplace
import ../salesagent
import ../statemachine
import ./types

logScope:
  topics = "marketplace sales cancelled"

type SaleCancelled* = ref object of SaleState

method `$`*(state: SaleCancelled): string =
  "SaleCancelled"

proc slotIsFilledByMe(
    marketplace: AbstractMarketplace, slot: SlotId
): Future[bool] {.async: (raises: [CancelledError, MarketplaceError]).} =
  let host = await marketplace.getHost(slot)
  let me = await marketplace.getSigner()

  return host == me.some

method run*(
    state: SaleCancelled, machine: Machine
): Future[?State] {.async: (raises: []).} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let marketplace = agent.context.marketplace

  try:
    if await slotIsFilledByMe(marketplace, data.slotInfo.slotId):
      debug "Collecting collateral and partial payout", slotId = data.slotInfo.slotId

      try:
        await marketplace.freeSlot(data.slotInfo.slotId)
      except SlotStateMismatchError as e:
        warn "Failed to free slot because slot is already free", error = e.msg

    if onCleanUp =? agent.onCleanUp:
      await onCleanUp(reprocessSlot = false)

    warn "Sale cancelled due to timeout", slotId = data.slotInfo.slotId
  except CancelledError as e:
    trace "SaleCancelled.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SaleCancelled.run", error = e.msgDetail
    return some State(SaleErrored(error: e))
