import pkg/questionable/results
import ../../../clock
import ../../../logutils
import ../../../utils/exceptions
import ../../abstractmarketplace
import ../../storageinterface
import ../statemachine
import ../salesagent
import ../metrics
import ./filling
import ./cancelled
import ./types
import ./failed

logScope:
  topics = "marketplace sales initial-proving"

type SaleInitialProving* = ref object of SaleState

method `$`*(state: SaleInitialProving): string =
  "SaleInitialProving"

method onCancelled*(state: SaleInitialProving, request: StorageRequest): ?State =
  return some State(SaleCancelled())

method onFailed*(state: SaleInitialProving, request: StorageRequest): ?State =
  return some State(SaleFailed())

proc waitUntilNextPeriod(clock: Clock, periodicity: Periodicity) {.async.} =
  trace "Waiting until next period"
  let period = periodicity.periodOf(clock.now())
  let periodEnd = periodicity.periodEnd(period)
  await clock.waitUntil((periodEnd + 1'u8).toSecondsSince1970)

proc waitForStableChallenge(
    marketplace: AbstractMarketplace,
    clock: Clock,
    periodicity: Periodicity,
    slotId: SlotId,
) {.async.} =
  let downtime = marketplace.proofDowntime()
  await clock.waitUntilNextPeriod(periodicity)
  while (await marketplace.getPointer(slotId)) > (256 - downtime):
    await clock.waitUntilNextPeriod(periodicity)

method run*(
    state: SaleInitialProving, machine: Machine
): Future[?State] {.async: (raises: []).} =
  let data = SalesAgent(machine).data
  let context = SalesAgent(machine).context
  let marketplace = context.marketplace
  let storage = context.storage
  let clock = context.clock

  without request =? data.request:
    raiseAssert "no sale request"

  try:
    let periodicity = marketplace.periodicity()

    debug "Waiting for a proof challenge that is valid for the entire period"
    let slot = Slot(request: request, slotIndex: data.slotIndex)
    await waitForStableChallenge(marketplace, clock, periodicity, slot.id)
    let provingPeriod = periodicity.periodOf(StorageTimestamp.init(clock.now()))

    info "Generating initial proof",
      provingPeriod = provingPeriod,
      requestId = data.requestId,
      slotIndex = data.slotIndex
    let cid = request.content.cid
    let slotIndex = data.slotIndex
    let challenge = await context.marketplace.getChallenge(slot.id)
    # Deadline is periodEnd - proof must be generated before the period closes.
    let periodEnd =
      (periodicity.periodStart(provingPeriod) + periodicity.seconds).toSecondsSince1970

    without proof =?
      (await storage.proveSlot(cid, slotIndex, challenge).withTimeout(clock, periodEnd)),
      err:
      error "Failed to generate initial proof", error = err.msg
      return some State(SaleErrored(error: err))
    let periodAtFinish = periodicity.periodOf(StorageTimestamp.init(clock.now()))
    if periodAtFinish != provingPeriod:
      warn "Initial proof generated after period rollover",
        provingPeriod = provingPeriod, periodAtFinish = periodAtFinish

    context.metrics.increaseNumberOfProofs(provingPeriod)

    info "Finished initial proof calculation",
      provingPeriod = periodAtFinish,
      requestId = data.requestId,
      slotIndex = data.slotIndex

    return some State(SaleFilling(proof: proof))
  except CancelledError as e:
    trace "SaleInitialProving.run onCleanUp was cancelled", error = e.msgDetail
  except CatchableError as e:
    error "Error during SaleInitialProving.run", error = e.msgDetail
    return some State(SaleErrored(error: e))
