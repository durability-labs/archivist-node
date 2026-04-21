import pkg/metrics
import ../statemachine
import ../../../utils/exceptions
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

  purchase.future.fail(state.error)
