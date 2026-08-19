import pkg/chronos
import pkg/questionable
import pkg/questionable/results

import ./types
import ../statemachine
import ../salesagent
import ../salesdata
import ../../contracts/requests
import ../../abstractmarketplace
import ../../storageinterface
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
  let storage = agent.context.storage

  logScope:
    slot = data.slotInfo

  error "Error", error = state.error

  try:
    await data.errorBackoff.applyDelay()

    let host = await marketplace.getHost(data.slotInfo.slotId)
    if host.isSome and host.unsafeGet == (await marketplace.getSigner()):
      debug "Errored slot is in MySlots. Restarting state machine..."
      return some State(SaleUnknown())

    trace "Errored slot is not in MySlots."
    if request =? data.slotInfo.request and slotIndex =? data.slotInfo.slotIndex:
      if error =? (await storage.deleteSlot(request.content.cid, slotIndex)).errorOption:
        error "Error deleting slot", error = error.msg
  except CancelledError as e:
    trace "SaleErrored.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SaleErrored.run", error = e.msgDetail
    return some State(SaleErrored(error: e))

  await performCleanUpExit(state, agent)
