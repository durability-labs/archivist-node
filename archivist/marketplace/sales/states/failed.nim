import pkg/chronos
import ../../../logutils
import ../../../utils/exceptions
import ../../../marketplace/abstractmarketplace
import ../../storageinterface
import ../salesagent
import ../statemachine
import ./types

logScope:
  topics = "marketplace sales failed"

type
  SaleFailed* = ref object of SaleState
  SaleFailedError* = object of SaleError

method `$`*(state: SaleFailed): string =
  "SaleFailed"

method run*(
    state: SaleFailed, machine: Machine
): Future[?State] {.async: (raises: []).} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let context = agent.context
  let marketplace = context.marketplace
  let storage = context.storage

  without request =? data.request:
    raiseAssert "no sale request"

  try:
    let slot = Slot(request: request, slotIndex: data.slotIndex)
    debug "Removing slot from mySlots",
      requestId = data.requestId, slotIndex = data.slotIndex

    await marketplace.freeSlot(slot.id)

    # Delete slot from the repostore
    if request =? data.request:
      if err =?
          (await storage.deleteSlot(request.content.cid, data.slotIndex)).errorOption:
        error "Failed to mark slot as failed", error = err.msg

    let error = newException(SaleFailedError, "Sale failed")
    return some State(SaleErrored(error: error))
  except CancelledError as e:
    trace "SaleFailed.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SaleFailed.run", error = e.msgDetail
    return some State(SaleErrored(error: e))
