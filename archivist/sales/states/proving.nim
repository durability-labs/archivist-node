import std/options
import pkg/questionable/results
import ../../clock
import ../../logutils
import ../../utils/exceptions
import ../../marketplace/abstractmarketplace
import ../../marketplace/storageinterface
import ../statemachine
import ../salesagent
import ../salescontext
import ./cancelled
import ./failed
import ./errored
import ./payout

logScope:
  topics = "marketplace sales proving"

type
  SlotFreedError* = object of CatchableError
  SlotNotFilledError* = object of CatchableError
  SaleProving* = ref object of SaleState

method prove*(
    state: SaleProving,
    slot: Slot,
    challenge: ProofChallenge,
    marketplace: AbstractMarketplace,
    storage: StorageInterface,
    provingPeriod: Period,
) {.base, async.} =
  try:
    let cid = slot.request.content.cid
    let slotIndex = slot.slotIndex
    without proof =? await storage.proveSlot(cid, slotIndex, challenge), err:
      error "Failed to generate proof", error = err.msg
      # In this state, there's nothing we can do except try again next time.
      return
    info "Submitting proof", provingPeriod = provingPeriod, slotId = slot.id
    await marketplace.submitProof(slot.id, proof)
  except CancelledError as error:
    trace "Submitting proof cancelled"
    raise error
  except CatchableError as e:
    error "Submitting proof failed",
      provingPeriod = provingPeriod, slotId = slot.id, msg = e.msgDetail

proc proveLoop(
    state: SaleProving,
    marketplace: AbstractMarketplace,
    storage: StorageInterface,
    clock: Clock,
    request: StorageRequest,
    slotIndex: uint64,
) {.async.} =
  let slot = Slot(request: request, slotIndex: slotIndex)
  let slotId = slot.id

  logScope:
    provingPeriod = provingPeriod
    requestId = request.id
    slotIndex
    slotId = slot.id

  proc getCurrentPeriod(): Future[Period] {.async.} =
    let periodicity = await marketplace.periodicity()
    return periodicity.periodOf(clock.now().Timestamp)

  proc waitUntilPeriod(period: Period) {.async.} =
    let periodicity = await marketplace.periodicity()
    # Ensure that we're past the period boundary by waiting an additional second
    await clock.waitUntil((periodicity.periodStart(period) + 1).toSecondsSince1970)

  while true:
    let provingPeriod = await getCurrentPeriod()
    let slotState = await marketplace.slotState(slot.id)

    case slotState
    of SlotState.Filled:
      debug "Proving for new period"
      if (await marketplace.isProofRequired(slotId)) or
          (await marketplace.willProofBeRequired(slotId)):
        let challenge = await marketplace.getChallenge(slotId)
        info "Generating required proof", challenge = challenge
        await state.prove(slot, challenge, marketplace, storage, provingPeriod)
        let periodAtFinish = await getCurrentPeriod()
        if periodAtFinish != provingPeriod:
          warn "Failed to generate proof in time", periodAtFinish = periodAtFinish
    of SlotState.Cancelled:
      debug "Slot reached cancelled state"
      # do nothing, let onCancelled callback take care of it
    of SlotState.Repair:
      warn "Slot was forcible freed"
      let message = "Slot was forcible freed and host was removed from its hosting"
      raise newException(SlotFreedError, message)
    of SlotState.Failed:
      debug "Slot reached failed state"
      # do nothing, let onFailed callback take care of it
    of SlotState.Finished:
      debug "Slot reached finished state"
      return # exit the loop
    else:
      let message = "Slot is not in Filled state, but in state: " & $slotState
      raise newException(SlotNotFilledError, message)

    debug "waiting until next period"
    await waitUntilPeriod(provingPeriod + 1)

method `$`*(state: SaleProving): string =
  "SaleProving"

method onCancelled*(state: SaleProving, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleProving, request: StorageRequest): ?State =
  return some State(SaleFailed())

method run*(
    state: SaleProving, machine: Machine
): Future[?State] {.async: (raises: []).} =
  let data = SalesAgent(machine).data
  let context = SalesAgent(machine).context
  let marketplace = context.marketplace
  let storage = context.storage
  let clock = context.clock

  without request =? data.request:
    raiseAssert "no sale request"

  try:
    await state.proveLoop(marketplace, storage, clock, request, data.slotIndex)
    debug "Stopping proving.", requestId = data.requestId, slotIndex = data.slotIndex
    return some State(SalePayout())
  except CancelledError:
    trace "proving loop cancelled"
  except CatchableError as e:
    error "Proving failed",
      msg = e.msg, typ = $(type e), stack = e.getStackTrace(), error = e.msgDetail
    return some State(SaleErrored(error: e))
