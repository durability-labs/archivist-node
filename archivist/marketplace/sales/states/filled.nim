import pkg/chronos
import pkg/questionable
import pkg/questionable/results

import ../../../logutils
import ../../../utils/exceptions
import ../../abstractmarketplace
import ../../storageinterface
import ../statemachine
import ../salesagent
import ./types
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
  let storage = context.storage

  try:
    let host = await marketplace.getHost(data.slotInfo.slotId)
    let me = await marketplace.getSigner()

    if host == me.some:
      info "Slot succesfully filled", slotId = data.slotInfo.slotId

      without slot =? data.slotInfo.slot:
        raiseAssert "no sale slot"

      if onFilled =? agent.onFilled:
        onFilled(request, data.slotIndex)

      # Add buffer past contract end so overlay data survives through the
      # last proof window. Buffer covers period (last proof window) +
      # proofTimeout (challenge window). Without this, maintenance can drop
      # the overlay while the proving loop is still running its last proof.
      let expiry = await marketplace.getRequestEnd(slot.request.id)
      let periodicity = marketplace.periodicity()
      let buffer = periodicity.seconds + marketplace.proofTimeout()
      let expiryWithBuffer = expiry + buffer
      let cid = slot.request.content.cid
      let slotIndex = slot.slotIndex
      if err =?
          (await storage.updateSlotExpiry(cid, slotIndex, expiryWithBuffer)).errorOption:
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
