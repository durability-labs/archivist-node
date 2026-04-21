import pkg/metrics
import ../../../utils/exceptions
import ../../../logutils
import ../statemachine
import ./types

declareCounter(archivist_purchases_unknown, "archivist purchases unknown")

method `$`*(state: PurchaseUnknown): string =
  "unknown"

method run*(
    state: PurchaseUnknown, machine: Machine
): Future[?State] {.async: (raises: []).} =
  try:
    archivist_purchases_unknown.inc()
    let purchase = Purchase(machine)
    if (request =? await purchase.marketplace.getRequest(purchase.requestId)) and
        (requestState =? await purchase.marketplace.requestState(purchase.requestId)):
      purchase.request = some request

      case requestState
      of RequestState.New:
        return some State(PurchaseSubmitted())
      of RequestState.Started:
        return some State(PurchaseStarted())
      of RequestState.Cancelled:
        return some State(PurchaseCancelled())
      of RequestState.Finished:
        return some State(PurchaseFinished())
      of RequestState.Failed:
        return some State(PurchaseFailed())
  except CancelledError as e:
    trace "PurchaseUnknown.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during PurchaseUnknown.run", error = e.msgDetail
    return some State(PurchaseErrored(error: e))
