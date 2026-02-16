import std/sets
import std/sequtils
import pkg/chronos
import pkg/questionable/results
import pkg/stew/endians2
import ../clock
import ../logutils
import ./abstractmarketplace
import ./validation/validationconfig

export abstractmarketplace
export sets
export validationconfig

type Validation* = ref object
  slots: HashSet[SlotId]
  clock: Clock
  marketplace: AbstractMarketplace
  subscriptions: seq[Subscription]
  running: Future[void]
  config: ValidationConfig

logScope:
  topics = "archivist validator"

proc new*(
    _: type Validation,
    clock: Clock,
    marketplace: AbstractMarketplace,
    config: ValidationConfig,
): Validation =
  Validation(clock: clock, marketplace: marketplace, config: config)

proc slots*(validation: Validation): seq[SlotId] =
  validation.slots.toSeq

proc getCurrentPeriod(validation: Validation): ProofPeriod =
  let periodicity = validation.marketplace.periodicity
  return periodicity.periodOf(validation.clock.now())

proc waitUntilNextPeriod(validation: Validation) {.async.} =
  let period = validation.getCurrentPeriod()
  let periodicity = validation.marketplace.periodicity
  let periodEnd = periodicity.periodEnd(period)
  let targetTime = (periodEnd + 1).toSecondsSince1970
  trace "Waiting until next period", currentPeriod = period, periodEnd, targetTime, now = validation.clock.now()
  await validation.clock.waitUntil(targetTime)
  trace "Finished waiting for next period", now = validation.clock.now()

func groupIndexForSlotId*(slotId: SlotId, validationGroups: ValidationGroups): uint16 =
  let a = slotId.toArray
  let slotIdInt64 = uint64.fromBytesBE(a)
  (slotIdInt64 mod uint64(validationGroups)).uint16

func maxSlotsConstraintRespected(validation: Validation): bool =
  validation.config.maxSlots == 0 or validation.slots.len < validation.config.maxSlots

func shouldValidateSlot(validation: Validation, slotId: SlotId): bool =
  without validationGroups =? validation.config.groups:
    return true
  groupIndexForSlotId(slotId, validationGroups) == validation.config.groupIndex

proc subscribeSlotFilled(validation: Validation) {.async.} =
  proc onSlotFilled(requestId: RequestId, slotIndex: uint64) =
    if not validation.maxSlotsConstraintRespected:
      return
    let slotId = slotId(requestId, slotIndex)
    if validation.shouldValidateSlot(slotId):
      trace "Adding slot", slotId
      validation.slots.incl(slotId)

  let subscription = await validation.marketplace.subscribeSlotFilled(onSlotFilled)
  validation.subscriptions.add(subscription)

proc removeSlotsThatHaveEnded(validation: Validation) {.async.} =
  var ended: HashSet[SlotId]
  let slots = validation.slots
  for slotId in slots:
    let state = await validation.marketplace.slotState(slotId)
    if state != SlotState.Filled:
      trace "Removing slot", slotId, slotState = state
      ended.incl(slotId)
  validation.slots.excl(ended)

proc markProofAsMissing(
    validation: Validation, slotId: SlotId, period: ProofPeriod
) {.async.} =
  logScope:
    currentPeriod = validation.getCurrentPeriod()

  try:
    if await validation.marketplace.canMarkProofAsMissing(slotId, period):
      trace "Marking proof as missing", slotId, periodProofMissed = period
      await validation.marketplace.markProofAsMissing(slotId, period)
    else:
      let inDowntime {.used.} = await validation.marketplace.inDowntime(slotId)
      trace "Proof not missing", checkedPeriod = period, inDowntime
  except CancelledError:
    raise
  except CatchableError as e:
    error "Marking proof as missing failed", msg = e.msg

proc markProofsAsMissing(validation: Validation) {.async.} =
  let slots = validation.slots
  for slotId in slots:
    let previousPeriod = validation.getCurrentPeriod() - 1'u8
    await validation.markProofAsMissing(slotId, previousPeriod)

proc run(validation: Validation) {.async: (raises: []).} =
  trace "Validation started"
  try:
    while true:
      await validation.waitUntilNextPeriod()
      await validation.removeSlotsThatHaveEnded()
      await validation.markProofsAsMissing()
  except CancelledError:
    trace "Validation stopped"
    discard # do not propagate as run is asyncSpawned
  except CatchableError as e:
    error "Validation failed", msg = e.msg

proc findEpoch(validation: Validation, secondsAgo: uint64): SecondsSince1970 =
  return validation.clock.now - secondsAgo.int64

proc restoreHistoricalState(validation: Validation) {.async.} =
  trace "Restoring historical state..."
  let requestDurationLimit = validation.marketplace.requestDurationLimit
  let startTimeEpoch = validation.findEpoch(secondsAgo = requestDurationLimit.u64)
  let slotFilledEvents =
    await validation.marketplace.queryPastSlotFilledEvents(fromTime = startTimeEpoch)
  for event in slotFilledEvents:
    if not validation.maxSlotsConstraintRespected:
      break
    let slotId = slotId(event.requestId, event.slotIndex)
    let slotState = await validation.marketplace.slotState(slotId)
    if slotState == SlotState.Filled and validation.shouldValidateSlot(slotId):
      trace "Adding slot [historical]", slotId
      validation.slots.incl(slotId)
  trace "Historical state restored", numberOfSlots = validation.slots.len

proc start*(
    validation: Validation
): Future[?!void] {.async: (raises: [CancelledError]).} =
  try:
    trace "Starting validator",
      groups = validation.config.groups, groupIndex = validation.config.groupIndex
    await validation.subscribeSlotFilled()
    await validation.restoreHistoricalState()
    validation.running = validation.run()
    success()
  except CancelledError as error:
    raise error
  except CatchableError as error:
    failure error

proc stop*(validation: Validation) {.async: (raises: []).} =
  if not validation.running.isNil and not validation.running.finished:
    await validation.running.cancelAndWait()
  while validation.subscriptions.len > 0:
    let subscription = validation.subscriptions.pop()
    await noCancel subscription.unsubscribe()
