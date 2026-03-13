import pkg/chronos
import pkg/questionable
import pkg/questionable/results

import ./types
import ../statemachine
import ../salesagent
import ../salesdata
import ../../contracts/requests
import ../../abstractmarketplace
import ../../../logutils
import ../../../utils/exceptions
import ../../../utils/exponentialbackoff

logScope:
  topics = "marketplace sales errored"

method `$`*(state: SaleErrored): string =
  "SaleErrored"

proc isMySlot(
    marketplace: AbstractMarketplace, data: SalesData
): Future[bool] {.async.} =
  let slotId = slotId(data.requestId, data.slotIndex)
  let slotIds = await marketplace.mySlots()
  return slotId in slotIds

proc performCleanUpExit(
    state: SaleErrored, agent: SalesAgent
): Future[?State] {.async: (raises: []).} =
  trace "SaleErrored: Cleanup and exit"
  try:
    if onCleanUp =? agent.onCleanUp:
      await onCleanUp(reprocessSlot = state.reprocessSlot)
  except CancelledError as e:
    trace "SaleErrored.performCleanUpExit was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SaleErrored.performCleanUpExit", error = e.msgDetail
  return none State

method run*(
    state: SaleErrored, machine: Machine
): Future[?State] {.async: (raises: []).} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let marketplace = agent.context.marketplace
  let slotIndex = data.slotIndex

  try:
    await data.errorBackoff.applyDelay()

    if await isMySlot(marketplace, data):
      debug "Errored slot is in MySlots. Restarting state machine..."
      return some State(SaleUnknown())
    else:
      trace "Errored slot is not in MySlots."
  except CancelledError as e:
    trace "SaleErrored.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SaleError.isMySlot", error = e.msgDetail
    return some State(SaleErrored(error: e))

  return await performCleanUpExit(state, agent)
