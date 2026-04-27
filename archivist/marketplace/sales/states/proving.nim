import std/options
import pkg/questionable/results
import pkg/chronos
import ../../../clock
import ../../../logutils
import ../../../utils/exceptions
import ../../abstractmarketplace
import ../../storageinterface
import ../statemachine
import ../salesagent
import ../salescontext
import ../metrics
import ./cancelled
import ./failed
import ./types
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
    context: SalesContext,
    provingPeriod: ProofPeriod,
) {.base, async.} =
  try:
    let marketplace = context.marketplace
    let storage = context.storage
    let cid = slot.request.content.cid
    let slotIndex = slot.slotIndex
    without proof =? await storage.proveSlot(cid, slotIndex, challenge), err:
      error "Failed to generate proof", error = err.msg
      # In this state, there's nothing we can do except try again next time.
      return
    context.metrics.increaseNumberOfProofs(provingPeriod)
    info "Submitting proof", provingPeriod = provingPeriod, slot = slot
    await marketplace.submitProof(slot.id, proof)
  except CancelledError as error:
    trace "Submitting proof cancelled"
    raise error
  except CatchableError as e:
    error "Submitting proof failed",
      provingPeriod = provingPeriod, slot = slot, msg = e.msgDetail

proc proveLoop(state: SaleProving, context: SalesContext, slot: Slot) {.async.} =
  let marketplace = context.marketplace
  let clock = context.clock

  logScope:
    provingPeriod = provingPeriod
    slot = slot

  proc getCurrentPeriod(): ProofPeriod =
    let periodicity = marketplace.periodicity()
    return periodicity.periodOf(clock.now())

  proc waitUntilPeriod(period: ProofPeriod) {.async.} =
    let periodicity = marketplace.periodicity()
    # Ensure that we're past the period boundary by waiting an additional second
    await clock.waitUntil((periodicity.periodStart(period) + 1'u8).toSecondsSince1970)

  while true:
    let provingPeriod = getCurrentPeriod()
    let slotState = await marketplace.slotState(slot.id)

    case slotState
    of SlotState.Filled:
      debug "Proving for new period"
      if (await marketplace.isProofRequired(slot.id)) or
          (await marketplace.willProofBeRequired(slot.id)):
        let challenge = await marketplace.getChallenge(slot.id)
        info "Generating required proof", challenge = challenge
        # Deadline is the end of the current proving period. Proof must be
        # generated and submitted before periodEnd.
        let periodicity = marketplace.periodicity()
        let periodEnd = periodicity.periodEnd(provingPeriod).toSecondsSince1970
        try:
          await state.prove(slot, challenge, context, provingPeriod).withTimeout(
            clock, periodEnd
          )
        except Timeout:
          warn "Proof generation timed out", provingPeriod = provingPeriod
          await waitUntilPeriod(provingPeriod + 1'u8)
          continue
        let periodAtFinish = getCurrentPeriod()
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
    await waitUntilPeriod(provingPeriod + 1'u8)

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

  without slot =? data.slotInfo.slot:
    raiseAssert "no sale slot"

  try:
    await state.proveLoop(context, slot)
    debug "Stopping proving.", slot = data.slotInfo
    return some State(SalePayout())
  except CancelledError:
    trace "proving loop cancelled"
  except CatchableError as e:
    error "Proving failed",
      msg = e.msg, typ = $(type e), stack = e.getStackTrace(), error = e.msgDetail
    return some State(SaleErrored(error: e))
