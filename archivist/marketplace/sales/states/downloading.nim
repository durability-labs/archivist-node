import pkg/chronos
import pkg/questionable
import pkg/questionable/results

import ../../../blocktype as bt
import ../../../logutils
import ../../../utils/exceptions
import ../../abstractmarketplace
import ../../storageinterface
import ../salesagent
import ../statemachine
import ./cancelled
import ./failed
import ./filled
import ./initialproving
import ./types

type SaleDownloading* = ref object of SaleState

logScope:
  topics = "marketplace sales downloading"

method `$`*(state: SaleDownloading): string =
  "SaleDownloading"

method onCancelled*(state: SaleDownloading, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleDownloading, request: StorageRequest): ?State =
  return some State(SaleFailed())

method onSlotFilled*(
    state: SaleDownloading, requestId: RequestId, slotIndex: uint64
): ?State =
  return some State(SaleFilled())

method run*(
    state: SaleDownloading, machine: Machine
): Future[?State] {.async: (raises: []).} =
  let agent = SalesAgent(machine)
  let data = agent.data
  let context = agent.context
  let marketplace = context.marketplace
  let storage = context.storage

  without slot =? data.slotInfo.slot:
    raiseAssert "no sale slot"

  logScope:
    requestId = slot.request.id
    slotIndex = slot.slotIndex

  try:
    let requestId = slot.request.id
    let requestState = await marketplace.requestState(requestId)
    let repair = (await marketplace.slotState(slot.id)) == SlotState.Repair

    trace "Retrieving expiry"
    var expiry: StorageTimestamp
    if state =? requestState and state == RequestState.Started:
      expiry = await marketplace.getRequestEnd(requestId)
    else:
      expiry = await marketplace.requestExpiresAt(requestId)

    debug "Starting download"
    if err =? (
      await storage.storeSlot(
        slot.request.content.cid, slot.slotIndex, slot.request.ask.slotSize, expiry,
        repair,
      )
    ).errorOption:
      return some State(SaleErrored(error: err, reprocessSlot: false))

    debug "Download complete"
    return some State(SaleInitialProving())
  except CancelledError as e:
    trace "SaleDownloading.run was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SaleDownloading.run", error = e.msgDetail
    return some State(SaleErrored(error: e))
