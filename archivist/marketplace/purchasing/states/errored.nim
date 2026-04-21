import pkg/metrics
import ../statemachine
import ../../../utils/exceptions
import ../../../utils/exponentialbackoff
import ../../../logutils
import ./types

declareCounter(archivist_purchases_error, "archivist purchases error")

logScope:
  topics = "marketplace purchases errored"

method `$`*(state: PurchaseErrored): string =
  "errored"

method run*(
    state: PurchaseErrored, machine: Machine
): Future[?State] {.async: (raises: []).} =
  archivist_purchases_error.inc()
  let purchase = Purchase(machine)

  error "Purchasing error",
    error = state.error.msgDetail, requestId = purchase.requestId

  try:
    await purchase.errorBackoff.applyDelay()
    if purchase.requestId in await purchase.marketplace.myRequests():
      debug "Errored request is in myRequests. Restarting state machine"
      return some State(PurchaseUnknown())
    else:
      trace "Errored request is not in myRequests"
  except CancelledError:
    trace " PurchaseErrored was cancelled"
  except CatchableError as error:
    error "Error during PurchaseErrored.run", error = error.msg
    return some State(PurchaseErrored(error: error))

  purchase.future.fail(state.error)
