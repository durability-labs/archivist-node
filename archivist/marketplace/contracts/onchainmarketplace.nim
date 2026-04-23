import std/strformat
import std/strutils
import pkg/ethers
import pkg/questionable
import pkg/lrucache
import ../../utils/exceptions
import ../../logutils
import ../abstractmarketplace
import ./marketplacecontract
import ./proofs
import ./provider

export abstractmarketplace

logScope:
  topics = "marketplace onchain"

type
  OnChainMarketplace* = ref object of AbstractMarketplace
    contract: MarketplaceContract
    signer: Signer
    configuration: MarketplaceConfig
    requestCache: LruCache[string, StorageRequest]
    allowanceLock: AsyncLock

  MarketSubscription = abstractmarketplace.Subscription
  EventSubscription = ethers.Subscription
  OnChainMarketSubscription = ref object of MarketSubscription
    eventSubscription: EventSubscription

proc load(
    marketplace: OnchainMarketplace
): Future[?!void] {.async: (raises: [CancelledError]).} =
  try:
    marketplace.configuration = await marketplace.contract.configuration()
    success()
  except EthersError as error:
    failure(error)

proc load*(
    _: type OnChainMarketplace,
    contract: MarketplaceContract,
    requestCacheSize: uint16 = DefaultRequestCacheSize,
): Future[?!OnChainMarketplace] {.async: (raises: [CancelledError]).} =
  without signer =? contract.signer:
    raiseAssert("Marketplace contract should have a signer")
  let requestCache = newLruCache[string, StorageRequest](int(requestCacheSize))
  let marketplace =
    OnChainMarketplace(contract: contract, signer: signer, requestCache: requestCache)
  ?await marketplace.load()
  success marketplace

proc raiseMarketError(message: string) {.raises: [MarketplaceError].} =
  raise newException(MarketplaceError, message)

func prefixWith(suffix, prefix: string, separator = ": "): string =
  if prefix.len > 0:
    return &"{prefix}{separator}{suffix}"
  else:
    return suffix

template convertEthersError(msg: string = "", body) =
  try:
    body
  except EthersError as error:
    raiseMarketError(error.msgDetail.prefixWith(msg))

template withAllowanceLock*(marketplace: OnChainMarketplace, body: untyped) =
  if marketplace.allowanceLock.isNil:
    marketplace.allowanceLock = newAsyncLock()
  await marketplace.allowanceLock.acquire()
  try:
    body
  finally:
    try:
      marketplace.allowanceLock.release()
    except AsyncLockError as error:
      raise newException(Defect, error.msg, error)

proc approveFunds(
    marketplace: OnChainMarketplace, amount: Tokens
) {.async: (raises: [CancelledError, MarketplaceError]).} =
  debug "Approving tokens", amount
  convertEthersError("Failed to approve funds"):
    let tokenAddress = await marketplace.contract.token()
    let token = Erc20Token.new(tokenAddress, marketplace.signer)
    let owner = await marketplace.signer.getAddress()
    let spender = marketplace.contract.address
    marketplace.withAllowanceLock:
      let allowance = await token.allowance(owner, spender)
      discard await token.approve(spender, allowance + amount.u256).confirm(1)

method getZkeyHash*(marketplace: OnChainMarketplace): string =
  marketplace.configuration.proofs.zkeyHash

method getSigner*(
    marketplace: OnChainMarketplace
): Future[Address] {.async: (raises: [CancelledError, MarketplaceError]).} =
  convertEthersError("Failed to get signer address"):
    return await marketplace.signer.getAddress()

method periodicity*(marketplace: OnChainMarketplace): Periodicity =
  let period = marketplace.configuration.proofs.period
  Periodicity(seconds: period)

method proofTimeout*(marketplace: OnChainMarketplace): StorageDuration =
  marketplace.configuration.proofs.timeout

method repairRewardPercentage*(marketplace: OnChainMarketplace): uint8 =
  marketplace.configuration.collateral.repairRewardPercentage

method requestDurationLimit*(marketplace: OnChainMarketplace): StorageDuration =
  marketplace.configuration.requestDurationLimit

method proofDowntime*(marketplace: OnChainMarketplace): uint8 =
  marketplace.configuration.proofs.downtime

method getPointer*(
    marketplace: OnChainMarketplace, slotId: SlotId
): Future[uint8] {.async.} =
  convertEthersError("Failed to get slot pointer"):
    let overrides = CallOverrides(blockTag: some BlockTag.pending)
    return await marketplace.contract.getPointer(slotId, overrides)

method myRequests*(marketplace: OnChainMarketplace): Future[seq[RequestId]] {.async.} =
  convertEthersError("Failed to get my requests"):
    return await marketplace.contract.myRequests

method mySlots*(marketplace: OnChainMarketplace): Future[seq[SlotId]] {.async.} =
  convertEthersError("Failed to get my slots"):
    let slots = await marketplace.contract.mySlots()
    debug "Fetched my slots", numSlots = len(slots)

    return slots

method requestStorage(
    marketplace: OnChainMarketplace, request: StorageRequest
) {.async: (raises: [CancelledError, MarketplaceError]).} =
  convertEthersError("Failed to request storage"):
    debug "Requesting storage"
    await marketplace.approveFunds(request.totalPrice())
    discard await marketplace.contract.requestStorage(request).confirm(1)

method getRequest*(
    marketplace: OnChainMarketplace, id: RequestId
): Future[?StorageRequest] {.async: (raises: [CancelledError]).} =
  try:
    let key = $id

    if key in marketplace.requestCache:
      return some marketplace.requestCache[key]

    let request = await marketplace.contract.getRequest(id)
    marketplace.requestCache[key] = request
    return some request
  except Marketplace_UnknownRequest, KeyError:
    warn "Cannot retrieve the request", error = getCurrentExceptionMsg()
    return none StorageRequest
  except EthersError as e:
    error "Cannot retrieve the request", error = e.msg
    return none StorageRequest

method requestState*(
    marketplace: OnChainMarketplace, requestId: RequestId
): Future[?RequestState] {.async.} =
  convertEthersError("Failed to get request state"):
    try:
      let overrides = CallOverrides(blockTag: some BlockTag.pending)
      return some await marketplace.contract.requestState(requestId, overrides)
    except Marketplace_UnknownRequest:
      return none RequestState

method slotState*(
    marketplace: OnChainMarketplace, slotId: SlotId
): Future[SlotState] {.async: (raises: [CancelledError, MarketplaceError]).} =
  convertEthersError("Failed to fetch the slot state from the Marketplace contract"):
    let overrides = CallOverrides(blockTag: some BlockTag.pending)
    return await marketplace.contract.slotState(slotId, overrides)

method getRequestEnd*(
    marketplace: OnChainMarketplace, id: RequestId
): Future[StorageTimestamp] {.async.} =
  convertEthersError("Failed to get request end"):
    return await marketplace.contract.requestEnd(id)

method requestExpiresAt*(
    marketplace: OnChainMarketplace, id: RequestId
): Future[StorageTimestamp] {.async.} =
  convertEthersError("Failed to get request expiry"):
    return await marketplace.contract.requestExpiry(id)

method getHost(
    marketplace: OnChainMarketplace, slotId: SlotId
): Future[?Address] {.async: (raises: [CancelledError, MarketplaceError]).} =
  convertEthersError("Failed to get slot's host"):
    let address = await marketplace.contract.getHost(slotId)
    if address != Address.default:
      return some address
    else:
      return none Address

method currentCollateral*(
    marketplace: OnChainMarketplace, slotId: SlotId
): Future[Tokens] {.async: (raises: [MarketplaceError, CancelledError]).} =
  convertEthersError("Failed to get slot's current collateral"):
    return await marketplace.contract.currentCollateral(slotId)

method getActiveSlot*(
    marketplace: OnChainMarketplace, slotId: SlotId
): Future[?Slot] {.async.} =
  convertEthersError("Failed to get active slot"):
    try:
      return some await marketplace.contract.getActiveSlot(slotId)
    except Marketplace_SlotIsFree:
      return none Slot

method fillSlot(
    marketplace: OnChainMarketplace,
    requestId: RequestId,
    slotIndex: uint64,
    proof: Groth16Proof,
    collateral: Tokens,
) {.async: (raises: [CancelledError, MarketplaceError]).} =
  convertEthersError("Failed to fill slot"):
    logScope:
      requestId
      slotIndex

    try:
      await marketplace.approveFunds(collateral)

      # Add 10% to gas estimate to deal with different evm code flow when we
      # happen to be the last one to fill a slot in this request
      trace "estimating gas for fillSlot"
      let gas =
        await marketplace.contract.estimateGas.fillSlot(requestId, slotIndex, proof)
      let gasLimit = (gas * 110) div 100
      let overrides = TransactionOverrides(gasLimit: some gasLimit)

      trace "calling fillSlot on contract", estimatedGas = gas, gasLimit = gasLimit
      discard await marketplace.contract
      .fillSlot(requestId, slotIndex, proof, overrides)
      .confirm(1)
      trace "fillSlot transaction completed"
    except Marketplace_SlotNotFree as parent:
      raise newException(
        SlotStateMismatchError, "Failed to fill slot because the slot is not free",
        parent,
      )

method freeSlot*(
    marketplace: OnChainMarketplace, slotId: SlotId
) {.async: (raises: [CancelledError, MarketplaceError]).} =
  convertEthersError("Failed to free slot"):
    try:
      # Add 200% to gas estimate to deal with different evm code flow when we
      # happen to be the one to make the request fail
      let gas = await marketplace.contract.estimateGas.freeSlot(slotId)
      let gasLimit = gas * 3
      let overrides = TransactionOverrides(gasLimit: some (gasLimit))

      trace "calling freeSlot on contract", estimatedGas = gas, gasLimit = gasLimit

      discard await marketplace.contract.freeSlot(slotId, overrides).confirm(1)
    except Marketplace_SlotIsFree as parent:
      raise newException(
        SlotStateMismatchError, "Failed to free slot, slot is already free", parent
      )

method withdrawFunds(
    marketplace: OnChainMarketplace, requestId: RequestId
) {.async: (raises: [CancelledError, MarketplaceError]).} =
  convertEthersError("Failed to withdraw funds"):
    discard await marketplace.contract.withdrawFunds(requestId).confirm(1)

method isProofRequired*(
    marketplace: OnChainMarketplace, id: SlotId
): Future[bool] {.async.} =
  convertEthersError("Failed to get proof requirement"):
    try:
      let overrides = CallOverrides(blockTag: some BlockTag.pending)
      return await marketplace.contract.isProofRequired(id, overrides)
    except Marketplace_SlotIsFree:
      return false

method willProofBeRequired*(
    marketplace: OnChainMarketplace, id: SlotId
): Future[bool] {.async.} =
  convertEthersError("Failed to get future proof requirement"):
    try:
      let overrides = CallOverrides(blockTag: some BlockTag.pending)
      return await marketplace.contract.willProofBeRequired(id, overrides)
    except Marketplace_SlotIsFree:
      return false

method getChallenge*(
    marketplace: OnChainMarketplace, id: SlotId
): Future[ProofChallenge] {.async.} =
  convertEthersError("Failed to get proof challenge"):
    let overrides = CallOverrides(blockTag: some BlockTag.pending)
    return await marketplace.contract.getChallenge(id, overrides)

method submitProof*(
    marketplace: OnChainMarketplace, id: SlotId, proof: Groth16Proof
) {.async: (raises: [CancelledError, MarketplaceError]).} =
  convertEthersError("Failed to submit proof"):
    try:
      discard await marketplace.contract.submitProof(id, proof).confirm(1)
    except Proofs_InvalidProof as parent:
      raise newException(
        ProofInvalidError, "Failed to submit proof because the proof is invalid", parent
      )

method markProofAsMissing*(
    marketplace: OnChainMarketplace, id: SlotId, period: ProofPeriod
) {.async: (raises: [CancelledError, MarketplaceError]).} =
  convertEthersError("Failed to mark proof as missing"):
    # Add 50% to gas estimate to deal with different evm code flow when we
    # happen to be the one to make the request fail
    let gas = await marketplace.contract.estimateGas.markProofAsMissing(id, period)
    let gasLimit = (gas * 150) div 100
    let overrides = TransactionOverrides(gasLimit: some gasLimit)

    trace "calling markProofAsMissing on contract",
      estimatedGas = gas, gasLimit = gasLimit

    discard
      await marketplace.contract.markProofAsMissing(id, period, overrides).confirm(1)

method canMarkProofAsMissing*(
    marketplace: OnChainMarketplace, id: SlotId, period: ProofPeriod
): Future[bool] {.async: (raises: [CancelledError]).} =
  try:
    let overrides = CallOverrides(blockTag: some BlockTag.pending)
    await marketplace.contract.canMarkProofAsMissing(id, period, overrides)
    return true
  except EthersError as e:
    trace "Proof cannot be marked as missing", msg = e.msg
    return false

method reserveSlot*(
    marketplace: OnChainMarketplace, requestId: RequestId, slotIndex: uint64
) {.async: (raises: [CancelledError, MarketplaceError]).} =
  convertEthersError("Failed to reserve slot"):
    try:
      # Add 25% to gas estimate to deal with different evm code flow when we
      # happen to be the last one that is allowed to reserve the slot
      let gas = await marketplace.contract.estimateGas.reserveSlot(requestId, slotIndex)
      let gasLimit = (gas * 125) div 100
      let overrides = TransactionOverrides(gasLimit: some gasLimit)

      trace "calling reserveSlot on contract", estimatedGas = gas, gasLimit = gasLimit

      discard await marketplace.contract
      .reserveSlot(requestId, slotIndex, overrides)
      .confirm(1)
    except SlotReservations_ReservationNotAllowed:
      raise newException(
        SlotReservationNotAllowedError,
        "Failed to reserve slot because reservation is not allowed",
      )

method canReserveSlot*(
    marketplace: OnChainMarketplace, requestId: RequestId, slotIndex: uint64
): Future[bool] {.async.} =
  convertEthersError("Unable to determine if slot can be reserved"):
    return await marketplace.contract.canReserveSlot(requestId, slotIndex)

method subscribeRequests*(
    marketplace: OnChainMarketplace, callback: OnRequest
): Future[MarketSubscription] {.async.} =
  proc onEvent(event: StorageRequested) {.raises: [].} =
    callback(event.requestId, event.ask, event.expiry)

  convertEthersError("Failed to subscribe to StorageRequested events"):
    let subscription = await marketplace.contract.subscribe(StorageRequested, onEvent)
    return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeSlotFilled*(
    marketplace: OnChainMarketplace, callback: OnSlotFilled
): Future[MarketSubscription] {.async.} =
  proc onEvent(event: SlotFilled) {.raises: [].} =
    callback(event.requestId, event.slotIndex)

  convertEthersError("Failed to subscribe to SlotFilled events"):
    let subscription = await marketplace.contract.subscribe(SlotFilled, onEvent)
    return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeSlotFilled*(
    marketplace: OnChainMarketplace,
    requestId: RequestId,
    slotIndex: uint64,
    callback: OnSlotFilled,
): Future[MarketSubscription] {.async.} =
  proc onSlotFilled(eventRequestId: RequestId, eventSlotIndex: uint64) =
    if eventRequestId == requestId and eventSlotIndex == slotIndex:
      callback(requestId, slotIndex)

  convertEthersError("Failed to subscribe to SlotFilled events"):
    return await marketplace.subscribeSlotFilled(onSlotFilled)

method subscribeSlotFreed*(
    marketplace: OnChainMarketplace, callback: OnSlotFreed
): Future[MarketSubscription] {.async.} =
  proc onEvent(event: SlotFreed) {.raises: [].} =
    callback(event.requestId, event.slotIndex)

  convertEthersError("Failed to subscribe to SlotFreed events"):
    let subscription = await marketplace.contract.subscribe(SlotFreed, onEvent)
    return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeSlotReservationsFull*(
    marketplace: OnChainMarketplace, callback: OnSlotReservationsFull
): Future[MarketSubscription] {.async.} =
  proc onEvent(event: SlotReservationsFull) {.raises: [].} =
    callback(event.requestId, event.slotIndex)

  convertEthersError("Failed to subscribe to SlotReservationsFull events"):
    let subscription =
      await marketplace.contract.subscribe(SlotReservationsFull, onEvent)
    return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeFulfillment(
    marketplace: OnChainMarketplace, callback: OnFulfillment
): Future[MarketSubscription] {.async.} =
  proc onEvent(event: RequestFulfilled) {.raises: [].} =
    callback(event.requestId)

  convertEthersError("Failed to subscribe to RequestFulfilled events"):
    let subscription = await marketplace.contract.subscribe(RequestFulfilled, onEvent)
    return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeFulfillment(
    marketplace: OnChainMarketplace, requestId: RequestId, callback: OnFulfillment
): Future[MarketSubscription] {.async.} =
  proc onEvent(event: RequestFulfilled) {.raises: [].} =
    if event.requestId == requestId:
      callback(event.requestId)

  convertEthersError("Failed to subscribe to RequestFulfilled events"):
    let subscription = await marketplace.contract.subscribe(RequestFulfilled, onEvent)
    return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeRequestFailed*(
    marketplace: OnChainMarketplace, callback: OnRequestFailed
): Future[MarketSubscription] {.async.} =
  proc onEvent(event: RequestFailed) {.raises: [].} =
    callback(event.requestId)

  convertEthersError("Failed to subscribe to RequestFailed events"):
    let subscription = await marketplace.contract.subscribe(RequestFailed, onEvent)
    return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeRequestFailed*(
    marketplace: OnChainMarketplace, requestId: RequestId, callback: OnRequestFailed
): Future[MarketSubscription] {.async.} =
  proc onEvent(event: RequestFailed) {.raises: [].} =
    if event.requestId == requestId:
      callback(event.requestId)

  convertEthersError("Failed to subscribe to RequestFailed events"):
    let subscription = await marketplace.contract.subscribe(RequestFailed, onEvent)
    return OnChainMarketSubscription(eventSubscription: subscription)

method subscribeProofSubmission*(
    marketplace: OnChainMarketplace, callback: OnProofSubmitted
): Future[MarketSubscription] {.async.} =
  proc onEvent(event: ProofSubmitted) {.raises: [].} =
    callback(event.id)

  convertEthersError("Failed to subscribe to ProofSubmitted events"):
    let subscription = await marketplace.contract.subscribe(ProofSubmitted, onEvent)
    return OnChainMarketSubscription(eventSubscription: subscription)

method unsubscribe*(subscription: OnChainMarketSubscription) {.async: (raises: []).} =
  try:
    await noCancel subscription.eventSubscription.unsubscribe()
  except ProviderError:
    discard

method queryPastSlotFilledEvents*(
    marketplace: OnChainMarketplace, fromBlock: BlockTag
): Future[seq[SlotFilled]] {.async: (raises: [CancelledError, MarketplaceError]).} =
  convertEthersError("Failed to get past SlotFilled events from block"):
    return
      await marketplace.contract.queryFilter(SlotFilled, fromBlock, BlockTag.latest)

method queryPastSlotFilledEvents*(
    marketplace: OnChainMarketplace, blocksAgo: int
): Future[seq[SlotFilled]] {.async: (raises: [CancelledError, MarketplaceError]).} =
  convertEthersError("Failed to get past SlotFilled events"):
    let fromBlock = await marketplace.contract.provider.pastBlockTag(blocksAgo)

    return await marketplace.queryPastSlotFilledEvents(fromBlock)

method queryPastSlotFilledEvents*(
    marketplace: OnChainMarketplace, fromTime: SecondsSince1970
): Future[seq[SlotFilled]] {.async: (raises: [CancelledError, MarketplaceError]).} =
  convertEthersError("Failed to get past SlotFilled events from time"):
    let fromBlock = await marketplace.contract.provider.blockNumberForEpoch(fromTime)
    return await marketplace.queryPastSlotFilledEvents(BlockTag.init(fromBlock))

method queryPastStorageRequestedEvents*(
    marketplace: OnChainMarketplace, fromBlock: BlockTag
): Future[seq[StorageRequested]] {.async.} =
  convertEthersError("Failed to get past StorageRequested events from block"):
    return await marketplace.contract.queryFilter(
      StorageRequested, fromBlock, BlockTag.latest
    )

method queryPastStorageRequestedEvents*(
    marketplace: OnChainMarketplace, blocksAgo: int
): Future[seq[StorageRequested]] {.async.} =
  convertEthersError("Failed to get past StorageRequested events"):
    let fromBlock = await marketplace.contract.provider.pastBlockTag(blocksAgo)

    return await marketplace.queryPastStorageRequestedEvents(fromBlock)
