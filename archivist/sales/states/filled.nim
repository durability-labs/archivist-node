import pkg/chronos
import pkg/questionable
import pkg/questionable/results

import ../../conf
import ../../logutils
import ../../utils/exceptions
import ../../marketplace/abstractmarketplace
import ../statemachine
import ../salesagent
import ./errored
import ./cancelled
import ./failed
import ./proving

when defined(archivist_system_testing_options):
  import ./provingsimulated

logScope:
  topics = "marketplace sales filled"

type
  SaleFilled* = ref object of SaleState
  HostMismatchError* = object of CatchableError

method onCancelled*(state: SaleFilled, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleFilled, request: StorageRequest): ?State =
  return some State(SaleFailed())

method `$`*(state: SaleFilled): string =
  "SaleFilled"

method run*(
    state: SaleFilled, machine: Machine
): Future[?State] {.async: (raises: []).} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let context = agent.context
  let marketplace = context.marketplace

  try:
    let host = await marketplace.getHost(data.requestId, data.slotIndex)
    let me = await marketplace.getSigner()

    if host == me.some:
      info "Slot succesfully filled",
        requestId = data.requestId, slotIndex = data.slotIndex

      without request =? data.request:
        raiseAssert "no sale request"

      if onFilled =? agent.onFilled:
        onFilled(request, data.slotIndex)

      without onExpiryUpdate =? context.onExpiryUpdate:
        raiseAssert "onExpiryUpdate callback not set"

      let requestEnd = await marketplace.getRequestEnd(data.requestId)
      if err =? (await onExpiryUpdate(request.content.cid, requestEnd)).errorOption:
        return some State(SaleErrored(error: err))

      when defined(archivist_system_testing_options):
        if context.simulateProofFailures > 0:
          info "Proving with failure rate", rate = context.simulateProofFailures
          return some State(
            SaleProvingSimulated(failEveryNProofs: context.simulateProofFailures)
          )

      return some State(SaleProving())
    else:
      let error = newException(HostMismatchError, "Slot filled by other host")
      return some State(SaleErrored(error: error))
  except CancelledError as e:
    trace "SaleFilled.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SaleFilled.run", error = e.msgDetail
    return some State(SaleErrored(error: e))
