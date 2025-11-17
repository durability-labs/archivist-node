import std/options
import pkg/questionable/results
import ../../clock
import ../../logutils
import ../../utils/exceptions
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
    onProve: OnProve,
    market: Market,
    provingPeriod: Period,
) {.base, async.} =
  try:
    without proof =? (await onProve(slot, challenge, provingPeriod)), err:
      error "Failed to generate proof", error = err.msg
      # In this state, there's nothing we can do except try again next time.
      return
    info "Submitting proof", provingPeriod = provingPeriod, slotId = slot.id
    await market.submitProof(slot.id, proof)
  except CancelledError as error:
    trace "Submitting proof cancelled"
    raise error
  except CatchableError as e:
    error "Submitting proof failed",
      provingPeriod = provingPeriod, slotId = slot.id, msg = e.msgDetail

proc proveLoop(
    state: SaleProving,
    market: Market,
    clock: Clock,
    request: StorageRequest,
    slotIndex: uint64,
    onProve: OnProve,
) {.async.} =
  let slot = Slot(request: request, slotIndex: slotIndex)
  let slotId = slot.id

  logScope:
    provingPeriod = provingPeriod
    requestId = request.id
    slotIndex
    slotId = slot.id

  proc getCurrentPeriod(): Future[Period] {.async.} =
    let periodicity = await market.periodicity()
    return periodicity.periodOf(clock.now().Timestamp)

  proc waitUntilPeriod(period: Period) {.async.} =
    let periodicity = await market.periodicity()
    # Ensure that we're past the period boundary by waiting an additional second
    await clock.waitUntil((periodicity.periodStart(period) + 1).toSecondsSince1970)

  while true:
    let provingPeriod = await getCurrentPeriod()
    let slotState = await market.slotState(slot.id)

    case slotState
    of SlotState.Filled:
      debug "Proving for new period"
      if (await market.isProofRequired(slotId)) or
          (await market.willProofBeRequired(slotId)):
        let challenge = await market.getChallenge(slotId)
        info "Generating required proof", challenge = challenge
        await state.prove(slot, challenge, onProve, market, provingPeriod)
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

  without request =? data.request:
    raiseAssert "no sale request"

  without onProve =? context.onProve:
    raiseAssert "onProve callback not set"

  without market =? context.market:
    raiseAssert("market not set")

  without clock =? context.clock:
    raiseAssert("clock not set")

  try:
    await state.proveLoop(market, clock, request, data.slotIndex, onProve)
    debug "Stopping proving.", requestId = data.requestId, slotIndex = data.slotIndex
    return some State(SalePayout())
  except CancelledError as e:
    trace "proving loop cancelled"
  except CatchableError as e:
    error "Proving failed",
      msg = e.msg, typ = $(type e), stack = e.getStackTrace(), error = e.msgDetail
    return some State(SaleErrored(error: e))
