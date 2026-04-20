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

  try:
    debug "Removing slot from mySlots", slotId = data.slotInfo.slotId
    await marketplace.freeSlot(data.slotInfo.slotId)

    if slot =? data.slotInfo.slot:
      let cid = slot.request.content.cid
      let slotIndex = slot.slotIndex
      if err =? (await storage.deleteSlot(cid, slotIndex)).errorOption:
        error "Failed to mark slot as failed", error = err.msg

    let error = newException(SaleFailedError, "Sale failed")
    return some State(SaleErrored(error: error))
  except CancelledError as e:
    trace "SaleFailed.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SaleFailed.run", error = e.msgDetail
    return some State(SaleErrored(error: e))
