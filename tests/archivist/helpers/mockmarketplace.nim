import std/sequtils
import std/tables
import std/hashes
import std/sets
import std/sugar
import pkg/questionable
import pkg/archivist/marketplace/abstractmarketplace
import pkg/archivist/marketplace/contracts/requests
import pkg/archivist/marketplace/contracts/proofs
import pkg/archivist/marketplace/contracts/config
import pkg/questionable/results

from pkg/ethers import BlockTag
import archivist/clock

import ../examples
import ./mockclock

export abstractmarketplace
export tables

logScope:
  topics = "mockMarket"

type
  MockMarketplace* = ref object of AbstractMarketplace
    periodicity: Periodicity
    activeRequests*: Table[Address, seq[RequestId]]
    activeSlots*: Table[Address, seq[SlotId]]
    requested*: seq[StorageRequest]
    requestEnds*: Table[RequestId, StorageTimestamp]
    requestExpiry*: Table[RequestId, StorageTimestamp]
    requestState*: Table[RequestId, RequestState]
    slotState*: Table[SlotId, SlotState]
    fulfilled*: seq[Fulfillment]
    filled*: seq[MockSlot]
    freed*: seq[SlotId]
    submitted*: seq[Groth16Proof]
    markedAsMissingProofs*: seq[SlotId]
    canBeMarkedAsMissing: HashSet[SlotId]
    withdrawn*: seq[RequestId]
    proofPointer*: uint8
    proofsRequired: HashSet[SlotId]
    proofsToBeRequired: HashSet[SlotId]
    proofChallenge*: ProofChallenge
    proofEnds: Table[SlotId, UInt256]
    signer: Address
    subscriptions: Subscriptions
    config*: MarketplaceConfig
    canReserveSlot*: bool
    errorOnReserveSlot*: ?(ref MarketplaceError)
    errorOnFillSlot*: ?(ref MarketplaceError)
    errorOnFreeSlot*: ?(ref MarketplaceError)
    errorOnGetHost*: ?(ref MarketplaceError)
    clock: Clock

  Fulfillment* = object
    requestId*: RequestId
    proof*: Groth16Proof
    host*: Address

  MockSlot* = object
    requestId*: RequestId
    host*: Address
    slotIndex*: uint64
    proof*: Groth16Proof
    timestamp: SecondsSince1970
    collateral*: Tokens

  Subscriptions = object
    onRequest: seq[RequestSubscription]
    onFulfillment: seq[FulfillmentSubscription]
    onSlotFilled: seq[SlotFilledSubscription]
    onSlotFreed: seq[SlotFreedSubscription]
    onSlotReservationsFull: seq[SlotReservationsFullSubscription]
    onRequestFailed: seq[RequestFailedSubscription]
    onProofSubmitted: seq[ProofSubmittedSubscription]

  MockSubscription = ref object of Subscription
    marketplace: MockMarketplace

  RequestSubscription* = ref object of MockSubscription
    callback: OnRequest

  FulfillmentSubscription* = ref object of MockSubscription
    requestId: ?RequestId
    callback: OnFulfillment

  SlotFilledSubscription* = ref object of MockSubscription
    requestId: ?RequestId
    slotIndex: ?uint64
    callback: OnSlotFilled

  SlotFreedSubscription* = ref object of MockSubscription
    callback: OnSlotFreed

  SlotReservationsFullSubscription* = ref object of MockSubscription
    callback: OnSlotReservationsFull

  RequestFailedSubscription* = ref object of MockSubscription
    requestId: ?RequestId
    callback: OnRequestFailed

  ProofSubmittedSubscription = ref object of MockSubscription
    callback: OnProofSubmitted

proc hash*(address: Address): Hash =
  hash(address.toArray)

proc hash*(requestId: RequestId): Hash =
  hash(requestId.toArray)

proc new*(_: type MockMarketplace, clock: Clock = MockClock.new()): MockMarketplace =
  let config = MarketplaceConfig(
    collateral: CollateralConfig(
      repairRewardPercentage: 10,
      maxNumberOfSlashes: 5,
      slashPercentage: 10,
      validatorRewardPercentage: 20,
    ),
    proofs: ProofConfig(
      period: 10'StorageDuration,
      timeout: 5'StorageDuration,
      downtime: 64.uint8,
      downtimeProduct: 67.uint8,
    ),
    reservations: SlotReservationsConfig(maxReservations: 3),
    requestDurationLimit: StorageDuration.init(60 * 60 * 24 * 30.stuint(40)),
  )
  MockMarketplace(
    signer: Address.example, config: config, canReserveSlot: true, clock: clock
  )

method getSigner*(
    marketplace: MockMarketplace
): Future[Address] {.async: (raises: [CancelledError, MarketplaceError]).} =
  return marketplace.signer

method periodicity*(mock: MockMarketplace): Periodicity =
  return Periodicity(seconds: mock.config.proofs.period)

method proofTimeout*(marketplace: MockMarketplace): StorageDuration =
  return marketplace.config.proofs.timeout

method requestDurationLimit*(marketplace: MockMarketplace): StorageDuration =
  return marketplace.config.requestDurationLimit

method proofDowntime*(marketplace: MockMarketplace): uint8 =
  return marketplace.config.proofs.downtime

method repairRewardPercentage*(marketplace: MockMarketplace): uint8 =
  return marketplace.config.collateral.repairRewardPercentage

method getPointer*(
    marketplace: MockMarketplace, slotId: SlotId
): Future[uint8] {.async.} =
  return marketplace.proofPointer

method requestStorage*(
    marketplace: MockMarketplace, request: StorageRequest
) {.async: (raises: [CancelledError, MarketplaceError]).} =
  let now = StorageTimestamp.init(marketplace.clock.now())
  let requestExpiresAt = now + request.expiry
  let requestEndsAt = now + request.ask.duration
  marketplace.requested.add(request)
  marketplace.requestExpiry[request.id] = requestExpiresAt
  marketplace.requestEnds[request.id] = requestEndsAt
  var subscriptions = marketplace.subscriptions.onRequest
  for subscription in subscriptions:
    subscription.callback(request.id, request.ask, requestExpiresAt)

method myRequests*(marketplace: MockMarketplace): Future[seq[RequestId]] {.async.} =
  marketplace.activeRequests .? [marketplace.signer] |? @[]

method mySlots*(marketplace: MockMarketplace): Future[seq[SlotId]] {.async.} =
  return marketplace.activeSlots[marketplace.signer]

method getRequest*(
    marketplace: MockMarketplace, id: RequestId
): Future[?StorageRequest] {.async: (raises: [CancelledError]).} =
  for request in marketplace.requested:
    if request.id == id:
      return some request
  return none StorageRequest

method getActiveSlot*(
    marketplace: MockMarketplace, id: SlotId
): Future[?Slot] {.async.} =
  for slot in marketplace.filled:
    if slotId(slot.requestId, slot.slotIndex) == id and
        request =? await marketplace.getRequest(slot.requestId):
      return some Slot(request: request, slotIndex: slot.slotIndex)
  return none Slot

method requestState*(
    marketplace: MockMarketplace, requestId: RequestId
): Future[?RequestState] {.async.} =
  return marketplace.requestState .? [requestId]

method slotState*(
    marketplace: MockMarketplace, slotId: SlotId
): Future[SlotState] {.async: (raises: [CancelledError, MarketplaceError]).} =
  if slotId notin marketplace.slotState:
    return SlotState.Free

  try:
    return marketplace.slotState[slotId]
  except KeyError:
    raiseAssert "SlotId not found in known slots (MockMarketplace.slotState)"

method getRequestEnd*(
    marketplace: MockMarketplace, id: RequestId
): Future[StorageTimestamp] {.async.} =
  return marketplace.requestEnds[id]

method requestExpiresAt*(
    marketplace: MockMarketplace, id: RequestId
): Future[StorageTimestamp] {.async.} =
  return marketplace.requestExpiry[id]

method getHost*(
    marketplace: MockMarketplace, slotId: SlotId
): Future[?Address] {.async: (raises: [CancelledError, MarketplaceError]).} =
  if error =? marketplace.errorOnGetHost:
    raise error

  for slot in marketplace.filled:
    if slotId(slot.requestId, slot.slotIndex) == slotId:
      return some slot.host
  return none Address

method currentCollateral*(
    marketplace: MockMarketplace, slotId: SlotId
): Future[Tokens] {.async: (raises: [MarketplaceError, CancelledError]).} =
  for slot in marketplace.filled:
    if slotId == slotId(slot.requestId, slot.slotIndex):
      return slot.collateral
  return 0'Tokens

proc emitSlotFilled*(
    marketplace: MockMarketplace, requestId: RequestId, slotIndex: uint64
) =
  var subscriptions = marketplace.subscriptions.onSlotFilled
  for subscription in subscriptions:
    let requestMatches =
      subscription.requestId.isNone or subscription.requestId == some requestId
    let slotMatches =
      subscription.slotIndex.isNone or subscription.slotIndex == some slotIndex
    if requestMatches and slotMatches:
      subscription.callback(requestId, slotIndex)

proc emitSlotFreed*(
    marketplace: MockMarketplace, requestId: RequestId, slotIndex: uint64
) =
  var subscriptions = marketplace.subscriptions.onSlotFreed
  for subscription in subscriptions:
    subscription.callback(requestId, slotIndex)

proc emitSlotReservationsFull*(
    marketplace: MockMarketplace, requestId: RequestId, slotIndex: uint64
) =
  var subscriptions = marketplace.subscriptions.onSlotReservationsFull
  for subscription in subscriptions:
    subscription.callback(requestId, slotIndex)

proc emitRequestFulfilled*(marketplace: MockMarketplace, requestId: RequestId) =
  var subscriptions = marketplace.subscriptions.onFulfillment
  for subscription in subscriptions:
    if subscription.requestId == requestId.some or subscription.requestId.isNone:
      subscription.callback(requestId)

proc emitRequestFailed*(marketplace: MockMarketplace, requestId: RequestId) =
  var subscriptions = marketplace.subscriptions.onRequestFailed
  for subscription in subscriptions:
    if subscription.requestId == requestId.some or subscription.requestId.isNone:
      subscription.callback(requestId)

proc fillSlot*(
    marketplace: MockMarketplace,
    requestId: RequestId,
    slotIndex: uint64,
    proof: Groth16Proof,
    host: Address,
    collateral = 0'Tokens,
) =
  if error =? marketplace.errorOnFillSlot:
    raise error

  let slot = MockSlot(
    requestId: requestId,
    slotIndex: slotIndex,
    proof: proof,
    host: host,
    timestamp: marketplace.clock.now,
    collateral: collateral,
  )
  marketplace.filled.add(slot)
  marketplace.slotState[slotId(slot.requestId, slot.slotIndex)] = SlotState.Filled
  marketplace.emitSlotFilled(requestId, slotIndex)

method fillSlot*(
    marketplace: MockMarketplace,
    requestId: RequestId,
    slotIndex: uint64,
    proof: Groth16Proof,
    collateral: Tokens,
) {.async: (raises: [CancelledError, MarketplaceError]).} =
  marketplace.fillSlot(requestId, slotIndex, proof, marketplace.signer, collateral)

method freeSlot*(
    marketplace: MockMarketplace, slotId: SlotId
) {.async: (raises: [CancelledError, MarketplaceError]).} =
  if error =? marketplace.errorOnFreeSlot:
    raise error

  marketplace.freed.add(slotId)
  for s in marketplace.filled:
    if slotId(s.requestId, s.slotIndex) == slotId:
      marketplace.emitSlotFreed(s.requestId, s.slotIndex)
      break
  marketplace.slotState[slotId] = SlotState.Free

method withdrawFunds*(
    marketplace: MockMarketplace, requestId: RequestId
) {.async: (raises: [CancelledError, MarketplaceError]).} =
  marketplace.withdrawn.add(requestId)
  if var myRequests =? marketplace.activeRequests .? [marketplace.signer]:
    myRequests.keepItIf(it != requestId)
    marketplace.activeRequests[marketplace.signer] = myRequests

proc setProofRequired*(mock: MockMarketplace, id: SlotId, required: bool) =
  if required:
    mock.proofsRequired.incl(id)
  else:
    mock.proofsRequired.excl(id)

method isProofRequired*(mock: MockMarketplace, id: SlotId): Future[bool] {.async.} =
  return mock.proofsRequired.contains(id)

proc setProofToBeRequired*(mock: MockMarketplace, id: SlotId, required: bool) =
  if required:
    mock.proofsToBeRequired.incl(id)
  else:
    mock.proofsToBeRequired.excl(id)

method willProofBeRequired*(mock: MockMarketplace, id: SlotId): Future[bool] {.async.} =
  return mock.proofsToBeRequired.contains(id)

method getChallenge*(
    mock: MockMarketplace, id: SlotId
): Future[ProofChallenge] {.async.} =
  return mock.proofChallenge

proc setProofEnd*(mock: MockMarketplace, id: SlotId, proofEnd: UInt256) =
  mock.proofEnds[id] = proofEnd

method submitProof*(
    mock: MockMarketplace, id: SlotId, proof: Groth16Proof
) {.async: (raises: [CancelledError, MarketplaceError]).} =
  mock.submitted.add(proof)
  for subscription in mock.subscriptions.onProofSubmitted:
    subscription.callback(id)

method markProofAsMissing*(
    marketplace: MockMarketplace, id: SlotId, period: ProofPeriod
) {.async: (raises: [CancelledError, MarketplaceError]).} =
  marketplace.markedAsMissingProofs.add(id)

proc setCanMarkProofAsMissing*(mock: MockMarketplace, id: SlotId, required: bool) =
  if required:
    mock.canBeMarkedAsMissing.incl(id)
  else:
    mock.canBeMarkedAsMissing.excl(id)

method canMarkProofAsMissing*(
    marketplace: MockMarketplace, id: SlotId, period: ProofPeriod
): Future[bool] {.async: (raises: [CancelledError]).} =
  return marketplace.canBeMarkedAsMissing.contains(id)

method reserveSlot*(
    marketplace: MockMarketplace, requestId: RequestId, slotIndex: uint64
) {.async: (raises: [CancelledError, MarketplaceError]).} =
  if error =? marketplace.errorOnReserveSlot:
    raise error

method canReserveSlot*(
    marketplace: MockMarketplace, requestId: RequestId, slotIndex: uint64
): Future[bool] {.async.} =
  return marketplace.canReserveSlot

func setCanReserveSlot*(marketplace: MockMarketplace, canReserveSlot: bool) =
  marketplace.canReserveSlot = canReserveSlot

func setErrorOnReserveSlot*(marketplace: MockMarketplace, error: ref MarketplaceError) =
  marketplace.errorOnReserveSlot =
    if error.isNil:
      none (ref MarketplaceError)
    else:
      some error

func setErrorOnFillSlot*(marketplace: MockMarketplace, error: ref MarketplaceError) =
  marketplace.errorOnFillSlot =
    if error.isNil:
      none (ref MarketplaceError)
    else:
      some error

func setErrorOnFreeSlot*(marketplace: MockMarketplace, error: ref MarketplaceError) =
  marketplace.errorOnFreeSlot =
    if error.isNil:
      none (ref MarketplaceError)
    else:
      some error

func setErrorOnGetHost*(marketplace: MockMarketplace, error: ref MarketplaceError) =
  marketplace.errorOnGetHost =
    if error.isNil:
      none (ref MarketplaceError)
    else:
      some error

method subscribeRequests*(
    marketplace: MockMarketplace, callback: OnRequest
): Future[Subscription] {.async.} =
  let subscription = RequestSubscription(marketplace: marketplace, callback: callback)
  marketplace.subscriptions.onRequest.add(subscription)
  return subscription

method subscribeFulfillment*(
    marketplace: MockMarketplace, callback: OnFulfillment
): Future[Subscription] {.async.} =
  let subscription = FulfillmentSubscription(
    marketplace: marketplace, requestId: none RequestId, callback: callback
  )
  marketplace.subscriptions.onFulfillment.add(subscription)
  return subscription

method subscribeFulfillment*(
    marketplace: MockMarketplace, requestId: RequestId, callback: OnFulfillment
): Future[Subscription] {.async.} =
  let subscription = FulfillmentSubscription(
    marketplace: marketplace, requestId: some requestId, callback: callback
  )
  marketplace.subscriptions.onFulfillment.add(subscription)
  return subscription

method subscribeSlotFilled*(
    marketplace: MockMarketplace, callback: OnSlotFilled
): Future[Subscription] {.async.} =
  let subscription =
    SlotFilledSubscription(marketplace: marketplace, callback: callback)
  marketplace.subscriptions.onSlotFilled.add(subscription)
  return subscription

method subscribeSlotFilled*(
    marketplace: MockMarketplace,
    requestId: RequestId,
    slotIndex: uint64,
    callback: OnSlotFilled,
): Future[Subscription] {.async.} =
  let subscription = SlotFilledSubscription(
    marketplace: marketplace,
    requestId: some requestId,
    slotIndex: some slotIndex,
    callback: callback,
  )
  marketplace.subscriptions.onSlotFilled.add(subscription)
  return subscription

method subscribeSlotFreed*(
    marketplace: MockMarketplace, callback: OnSlotFreed
): Future[Subscription] {.async.} =
  let subscription = SlotFreedSubscription(marketplace: marketplace, callback: callback)
  marketplace.subscriptions.onSlotFreed.add(subscription)
  return subscription

method subscribeSlotReservationsFull*(
    marketplace: MockMarketplace, callback: OnSlotReservationsFull
): Future[Subscription] {.async.} =
  let subscription =
    SlotReservationsFullSubscription(marketplace: marketplace, callback: callback)
  marketplace.subscriptions.onSlotReservationsFull.add(subscription)
  return subscription

method subscribeRequestFailed*(
    marketplace: MockMarketplace, callback: OnRequestFailed
): Future[Subscription] {.async.} =
  let subscription = RequestFailedSubscription(
    marketplace: marketplace, requestId: none RequestId, callback: callback
  )
  marketplace.subscriptions.onRequestFailed.add(subscription)
  return subscription

method subscribeRequestFailed*(
    marketplace: MockMarketplace, requestId: RequestId, callback: OnRequestFailed
): Future[Subscription] {.async.} =
  let subscription = RequestFailedSubscription(
    marketplace: marketplace, requestId: some requestId, callback: callback
  )
  marketplace.subscriptions.onRequestFailed.add(subscription)
  return subscription

method subscribeProofSubmission*(
    mock: MockMarketplace, callback: OnProofSubmitted
): Future[Subscription] {.async.} =
  let subscription = ProofSubmittedSubscription(marketplace: mock, callback: callback)
  mock.subscriptions.onProofSubmitted.add(subscription)
  return subscription

method queryPastStorageRequestedEvents*(
    marketplace: MockMarketplace, fromBlock: BlockTag
): Future[seq[StorageRequested]] {.async.} =
  return marketplace.requested.map(
    request =>
      StorageRequested(
        requestId: request.id,
        ask: request.ask,
        expiry: marketplace.requestExpiry[request.id],
      )
  )

method queryPastStorageRequestedEvents*(
    marketplace: MockMarketplace, blocksAgo: int
): Future[seq[StorageRequested]] {.async.} =
  return marketplace.requested.map(
    request =>
      StorageRequested(
        requestId: request.id,
        ask: request.ask,
        expiry: marketplace.requestExpiry[request.id],
      )
  )

method queryPastSlotFilledEvents*(
    marketplace: MockMarketplace, fromBlock: BlockTag
): Future[seq[SlotFilled]] {.async.} =
  return marketplace.filled.map(
    slot => SlotFilled(requestId: slot.requestId, slotIndex: slot.slotIndex)
  )

method queryPastSlotFilledEvents*(
    marketplace: MockMarketplace, blocksAgo: int
): Future[seq[SlotFilled]] {.async.} =
  return marketplace.filled.map(
    slot => SlotFilled(requestId: slot.requestId, slotIndex: slot.slotIndex)
  )

method queryPastSlotFilledEvents*(
    marketplace: MockMarketplace, fromTime: SecondsSince1970
): Future[seq[SlotFilled]] {.async.} =
  let filtered = marketplace.filled.filter(
    proc(slot: MockSlot): bool =
      return slot.timestamp >= fromTime
  )
  return filtered.map(
    slot => SlotFilled(requestId: slot.requestId, slotIndex: slot.slotIndex)
  )

method unsubscribe*(subscription: MockSubscription) {.async: (raises: []).} =
  let marketplace = subscription.marketplace
  marketplace.subscriptions.onRequest.keepItIf(subscription != it)
  marketplace.subscriptions.onFulfillment.keepItIf(subscription != it)
  marketplace.subscriptions.onSlotFilled.keepItIf(subscription != it)
  marketplace.subscriptions.onSlotFreed.keepItIf(subscription != it)
  marketplace.subscriptions.onRequestFailed.keepItIf(subscription != it)
  marketplace.subscriptions.onProofSubmitted.keepItIf(subscription != it)
  marketplace.subscriptions.onSlotReservationsFull.keepItIf(subscription != it)
