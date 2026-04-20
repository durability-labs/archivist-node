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

proc performCleanUpExit(state: SaleErrored, agent: SalesAgent) {.async: (raises: []).} =
  trace "SaleErrored: Cleanup and exit"
  try:
    if onCleanUp =? agent.onCleanUp:
      await onCleanUp(reprocessSlot = state.reprocessSlot)
  except CancelledError as e:
    trace "SaleErrored.performCleanUpExit was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SaleErrored.performCleanUpExit", error = e.msgDetail

method run*(
    state: SaleErrored, machine: Machine
): Future[?State] {.async: (raises: []).} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let marketplace = agent.context.marketplace

  logScope:
    slotId = data.slotInfo.slotId

  error "Error", error = state.error

  try:
    await data.errorBackoff.applyDelay()

    if data.slotInfo.slotId in await marketplace.mySlots():
      debug "Errored slot is in MySlots. Restarting state machine..."
      return some State(SaleUnknown())
    else:
      trace "Errored slot is not in MySlots."
  except CancelledError as e:
    trace "SaleErrored.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SaleError.isMySlot", error = e.msgDetail
    return some State(SaleErrored(error: e))

  await performCleanUpExit(state, agent)
