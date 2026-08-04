import pkg/chronos
import pkg/questionable
import pkg/ethers/erc20
import ../clock
import ../errors
import ./contracts/requests
import ./contracts/proofs
import ./periods

export chronos
export questionable
export requests
export proofs
export SecondsSince1970
export periods

type
  AbstractMarketplace* = ref object of RootObj
  MarketplaceError* = object of ArchivistError
  SlotStateMismatchError* = object of MarketplaceError
  SlotReservationNotAllowedError* = object of MarketplaceError
  ProofInvalidError* = object of MarketplaceError
  Subscription* = ref object of RootObj
  OnRequest* = proc(id: RequestId, ask: StorageAsk, expiry: StorageTimestamp) {.
    gcsafe, raises: []
  .}
  OnFulfillment* = proc(requestId: RequestId) {.gcsafe, raises: [].}
  OnSlotFilled* = proc(requestId: RequestId, slotIndex: uint64) {.gcsafe, raises: [].}
  OnSlotFreed* = proc(requestId: RequestId, slotIndex: uint64) {.gcsafe, raises: [].}
  OnSlotReservationsFull* =
    proc(requestId: RequestId, slotIndex: uint64) {.gcsafe, raises: [].}
  OnRequestFailed* = proc(requestId: RequestId) {.gcsafe, raises: [].}
  OnProofSubmitted* = proc(id: SlotId) {.gcsafe, raises: [].}
  ProofChallenge* = array[32, byte]

  # Marketplace events - located here due to the AbstractMarketplace abstraction
  MarketplaceEvent* = Event
  StorageRequested* = object of MarketplaceEvent
    requestId*: RequestId
    ask*: StorageAsk
    expiry*: StorageTimestamp

  SlotFilled* = object of MarketplaceEvent
    requestId* {.indexed.}: RequestId
    slotIndex*: uint64

  SlotFreed* = object of MarketplaceEvent
    requestId* {.indexed.}: RequestId
    slotIndex*: uint64

  SlotReservationsFull* = object of MarketplaceEvent
    requestId* {.indexed.}: RequestId
    slotIndex*: uint64

  RequestFulfilled* = object of MarketplaceEvent
    requestId* {.indexed.}: RequestId

  RequestFailed* = object of MarketplaceEvent
    requestId* {.indexed.}: RequestId

  ProofSubmitted* = object of MarketplaceEvent
    id*: SlotId

method getZkeyHash*(
    marketplace: AbstractMarketplace
): string {.base, gcsafe, raises: [].} =
  raiseAssert("not implemented")

method getSigner*(
    marketplace: AbstractMarketplace
): Future[Address] {.base, async: (raises: [CancelledError, MarketplaceError]).} =
  raiseAssert("not implemented")

method periodicity*(
    marketplace: AbstractMarketplace
): Periodicity {.base, gcsafe, raises: [].} =
  raiseAssert("not implemented")

method proofTimeout*(
    marketplace: AbstractMarketplace
): StorageDuration {.base, gcsafe, raises: [].} =
  raiseAssert("not implemented")

method repairRewardPercentage*(
    marketplace: AbstractMarketplace
): uint8 {.base, gcsafe, raises: [].} =
  raiseAssert("not implemented")

method requestDurationLimit*(
    marketplace: AbstractMarketplace
): StorageDuration {.base, gcsafe, raises: [].} =
  raiseAssert("not implemented")

method proofDowntime*(
    marketplace: AbstractMarketplace
): uint8 {.base, gcsafe, raises: [].} =
  raiseAssert("not implemented")

method getPointer*(
    marketplace: AbstractMarketplace, slotId: SlotId
): Future[uint8] {.base, async.} =
  raiseAssert("not implemented")

proc inDowntime*(
    marketplace: AbstractMarketplace, slotId: SlotId
): Future[bool] {.async.} =
  let downtime = marketplace.proofDowntime
  let pntr = await marketplace.getPointer(slotId)
  return pntr < downtime

method requestStorage*(
    marketplace: AbstractMarketplace, request: StorageRequest
) {.base, async: (raises: [CancelledError, MarketplaceError]).} =
  raiseAssert("not implemented")

method myRequests*(
    marketplace: AbstractMarketplace
): Future[seq[RequestId]] {.base, async.} =
  raiseAssert("not implemented")

method mySlots*(marketplace: AbstractMarketplace): Future[seq[SlotId]] {.base, async.} =
  raiseAssert("not implemented")

method getRequest*(
    marketplace: AbstractMarketplace, id: RequestId
): Future[?StorageRequest] {.base, async: (raises: [CancelledError]).} =
  raiseAssert("not implemented")

method requestState*(
    marketplace: AbstractMarketplace, requestId: RequestId
): Future[?RequestState] {.base, async.} =
  raiseAssert("not implemented")

method slotState*(
    marketplace: AbstractMarketplace, slotId: SlotId
): Future[SlotState] {.base, async: (raises: [CancelledError, MarketplaceError]).} =
  raiseAssert("not implemented")

method getRequestEnd*(
    marketplace: AbstractMarketplace, id: RequestId
): Future[StorageTimestamp] {.base, async.} =
  raiseAssert("not implemented")

method requestExpiresAt*(
    marketplace: AbstractMarketplace, id: RequestId
): Future[StorageTimestamp] {.base, async.} =
  raiseAssert("not implemented")

method getHost*(
    marketplace: AbstractMarketplace, slotId: SlotId
): Future[?Address] {.base, async: (raises: [CancelledError, MarketplaceError]).} =
  raiseAssert("not implemented")

proc getHost*(
    marketplace: AbstractMarketplace, requestId: RequestId, slotIndex: uint64
): Future[?Address] {.async: (raises: [CancelledError, MarketplaceError]).} =
  await marketplace.getHost(slotId(requestId, slotIndex))

method currentCollateral*(
    marketplace: AbstractMarketplace, slotId: SlotId
): Future[Tokens] {.base, async: (raises: [MarketplaceError, CancelledError]).} =
  raiseAssert("not implemented")

method getActiveSlot*(
    marketplace: AbstractMarketplace, slotId: SlotId
): Future[?Slot] {.base, async.} =
  raiseAssert("not implemented")

method fillSlot*(
    marketplace: AbstractMarketplace,
    requestId: RequestId,
    slotIndex: uint64,
    proof: Groth16Proof,
    collateral: Tokens,
) {.base, async: (raises: [CancelledError, MarketplaceError]).} =
  raiseAssert("not implemented")

method freeSlot*(
    marketplace: AbstractMarketplace, slotId: SlotId
) {.base, async: (raises: [CancelledError, MarketplaceError]).} =
  raiseAssert("not implemented")

method withdrawFunds*(
    marketplace: AbstractMarketplace, requestId: RequestId
) {.base, async: (raises: [CancelledError, MarketplaceError]).} =
  raiseAssert("not implemented")

method subscribeRequests*(
    marketplace: AbstractMarketplace, callback: OnRequest
): Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method isProofRequired*(
    marketplace: AbstractMarketplace, id: SlotId
): Future[bool] {.base, async.} =
  raiseAssert("not implemented")

method willProofBeRequired*(
    marketplace: AbstractMarketplace, id: SlotId
): Future[bool] {.base, async.} =
  raiseAssert("not implemented")

method getChallenge*(
    marketplace: AbstractMarketplace, id: SlotId
): Future[ProofChallenge] {.base, async.} =
  raiseAssert("not implemented")

method submitProof*(
    marketplace: AbstractMarketplace, id: SlotId, proof: Groth16Proof
) {.base, async: (raises: [CancelledError, MarketplaceError]).} =
  raiseAssert("not implemented")

method markProofAsMissing*(
    marketplace: AbstractMarketplace, id: SlotId, period: ProofPeriod
) {.base, async: (raises: [CancelledError, MarketplaceError]).} =
  raiseAssert("not implemented")

method canMarkProofAsMissing*(
    marketplace: AbstractMarketplace, id: SlotId, period: ProofPeriod
): Future[bool] {.base, async: (raises: [CancelledError]).} =
  raiseAssert("not implemented")

method reserveSlot*(
    marketplace: AbstractMarketplace, requestId: RequestId, slotIndex: uint64
) {.base, async: (raises: [CancelledError, MarketplaceError]).} =
  raiseAssert("not implemented")

method canReserveSlot*(
    marketplace: AbstractMarketplace, requestId: RequestId, slotIndex: uint64
): Future[bool] {.base, async.} =
  raiseAssert("not implemented")

method subscribeFulfillment*(
    marketplace: AbstractMarketplace, callback: OnFulfillment
): Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeFulfillment*(
    marketplace: AbstractMarketplace, requestId: RequestId, callback: OnFulfillment
): Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeSlotFilled*(
    marketplace: AbstractMarketplace, callback: OnSlotFilled
): Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeSlotFilled*(
    marketplace: AbstractMarketplace,
    requestId: RequestId,
    slotIndex: uint64,
    callback: OnSlotFilled,
): Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeSlotFreed*(
    marketplace: AbstractMarketplace, callback: OnSlotFreed
): Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeSlotReservationsFull*(
    marketplace: AbstractMarketplace, callback: OnSlotReservationsFull
): Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeRequestFailed*(
    marketplace: AbstractMarketplace, callback: OnRequestFailed
): Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeRequestFailed*(
    marketplace: AbstractMarketplace, requestId: RequestId, callback: OnRequestFailed
): Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeProofSubmission*(
    marketplace: AbstractMarketplace, callback: OnProofSubmitted
): Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method unsubscribe*(subscription: Subscription) {.base, async: (raises: []).} =
  raiseAssert("not implemented")

method queryPastSlotFilledEvents*(
    marketplace: AbstractMarketplace, fromBlock: BlockTag
): Future[seq[SlotFilled]] {.base, async: (raises: [CancelledError, MarketplaceError]).} =
  raiseAssert("not implemented")

method queryPastSlotFilledEvents*(
    marketplace: AbstractMarketplace, blocksAgo: int
): Future[seq[SlotFilled]] {.base, async: (raises: [CancelledError, MarketplaceError]).} =
  raiseAssert("not implemented")

method queryPastSlotFilledEvents*(
    marketplace: AbstractMarketplace, fromTime: SecondsSince1970
): Future[seq[SlotFilled]] {.base, async: (raises: [CancelledError, MarketplaceError]).} =
  raiseAssert("not implemented")

method queryPastStorageRequestedEvents*(
    marketplace: AbstractMarketplace, fromBlock: BlockTag
): Future[seq[StorageRequested]] {.base, async.} =
  raiseAssert("not implemented")

method queryPastStorageRequestedEvents*(
    marketplace: AbstractMarketplace, blocksAgo: int
): Future[seq[StorageRequested]] {.base, async.} =
  raiseAssert("not implemented")
