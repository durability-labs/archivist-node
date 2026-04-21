import pkg/metrics
import ../../../logutils
import ../../../utils/exceptions
import ../statemachine
import ./types

declareCounter(archivist_purchases_pending, "archivist purchases pending")

method `$`*(state: PurchasePending): string =
  "pending"

method run*(
    state: PurchasePending, machine: Machine
): Future[?State] {.async: (raises: []).} =
  archivist_purchases_pending.inc()
  let purchase = Purchase(machine)
  try:
    let request = !purchase.request
    await purchase.marketplace.requestStorage(request)
    return some State(PurchaseSubmitted())
  except CancelledError as e:
    trace "PurchasePending.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during PurchasePending.run", error = e.msgDetail
    return some State(PurchaseErrored(error: e))
