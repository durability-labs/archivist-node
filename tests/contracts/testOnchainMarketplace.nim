import std/options
import std/importutils
import pkg/chronos
import pkg/ethers/erc20
import archivist/contracts
import pkg/libp2p/cid
import pkg/lrucache
import ../asynctest
import ../testbed
import ./examples
import ./deployment

privateAccess(OnChainMarketplace) # enable access to private fields

# to see supportive information in the test output
# use `-d:"chronicles_enabled_topics:testOnchainMarketplace:DEBUG` option
# when compiling the test file
logScope:
  topics = "testOnChainMarketplace"

suite "On-Chain Marketplace":
  var testbed: Testbed
  var hardhat: Hardhat
  var provider: JsonRpcProvider
  var accounts: seq[Address]

  setupAll:
    testbed = await Testbed.start()
    hardhat = await testbed.hardhat.start()
    provider = testbed.eth.provider
    accounts = await provider.listAccounts()

  teardownAll:
    await testbed.stop()

  let proof = Groth16Proof.example

  var marketplace: OnChainMarketplace
  var contract: MarketplaceContract
  var token: Erc20Token
  var request: StorageRequest
  var slotIndex: uint64
  var periodicity: Periodicity
  var host: Signer
  var otherHost: Signer
  var hostRewardRecipient: Address

  proc expectedPayout(
      r: StorageRequest, startTimestamp: uint64, endTimestamp: uint64
  ): UInt256 =
    return (endTimestamp - startTimestamp).u256 * r.ask.pricePerSlotPerSecond

  proc switchAccount(account: Signer) =
    contract = contract.connect(account)
    token = token.connect(account)
    marketplace = OnChainMarketplace.new(contract, marketplace.rewardRecipient)

  setup:
    let address = MarketplaceContract.address(dummyVerifier = true)
    contract = MarketplaceContract.new(address, provider.getSigner())
    let config = await contract.configuration()
    hostRewardRecipient = accounts[2]

    marketplace = OnChainMarketplace.new(contract)
    let tokenAddress = await contract.token()
    token = Erc20Token.new(tokenAddress, provider.getSigner())

    periodicity = Periodicity(seconds: config.proofs.period)

    request = StorageRequest.example
    request.client = accounts[0]
    host = provider.getSigner(accounts[1])
    otherHost = provider.getSigner(accounts[3])

    slotIndex = request.ask.slots div 2

  teardown:
    await hardhat.reset()

  proc advanceToNextPeriod() {.async.} =
    let currentPeriod = periodicity.periodOf(await testbed.eth.time.now())
    await testbed.eth.time.advanceTo(periodicity.periodEnd(currentPeriod) + 1)

  proc advanceToCancelledRequest(request: StorageRequest) {.async.} =
    let expiry = (await marketplace.requestExpiresAt(request.id)).uint64 + 1
    await testbed.eth.time.advanceTo(expiry)

  proc waitUntilProofRequired(slotId: SlotId) {.async.} =
    await advanceToNextPeriod()
    while not (
      (await marketplace.isProofRequired(slotId)) and
      (await marketplace.getPointer(slotId)) < 250
    )
    :
      await advanceToNextPeriod()

  test "caches marketplace configuration":
    check isNone marketplace.configuration
    discard await marketplace.periodicity()
    check isSome marketplace.configuration

  test "fails to instantiate when contract does not have a signer":
    let storageWithoutSigner = contract.connect(provider)
    expect AssertionDefect:
      discard OnChainMarketplace.new(storageWithoutSigner)

  test "knows signer address":
    check (await marketplace.getSigner()) == (await provider.getSigner().getAddress())

  test "can retrieve proof periodicity":
    let periodicity = await marketplace.periodicity()
    let config = await contract.configuration()
    let periodLength = config.proofs.period
    check periodicity.seconds == periodLength

  test "can retrieve proof timeout":
    let proofTimeout = await marketplace.proofTimeout()
    let config = await contract.configuration()
    check proofTimeout == config.proofs.timeout

  test "supports marketplace requests":
    await marketplace.requestStorage(request)

  test "can retrieve previously submitted requests":
    check (await marketplace.getRequest(request.id)) == none StorageRequest
    await marketplace.requestStorage(request)
    let r = await marketplace.getRequest(request.id)
    check (r) == some request

  test "withdraws funds to client":
    let clientAddress = request.client

    await marketplace.requestStorage(request)
    await advanceToCancelledRequest(request)
    let startBalanceClient = await token.balanceOf(clientAddress)
    await marketplace.withdrawFunds(request.id)

    let endBalanceClient = await token.balanceOf(clientAddress)

    check endBalanceClient == (startBalanceClient + request.totalPrice)

  test "supports request subscriptions":
    var receivedIds: seq[RequestId]
    var receivedAsks: seq[StorageAsk]
    proc onRequest(id: RequestId, ask: StorageAsk, expiry: uint64) =
      receivedIds.add(id)
      receivedAsks.add(ask)

    let subscription = await marketplace.subscribeRequests(onRequest)
    await marketplace.requestStorage(request)

    check eventually receivedIds == @[request.id] and receivedAsks == @[request.ask]
    await subscription.unsubscribe()

  test "supports filling of slots":
    await marketplace.requestStorage(request)
    await marketplace.reserveSlot(request.id, slotIndex)
    await marketplace.fillSlot(
      request.id, slotIndex, proof, request.ask.collateralPerSlot
    )

  test "can retrieve host that filled slot":
    await marketplace.requestStorage(request)
    check (await marketplace.getHost(request.id, slotIndex)) == none Address
    await marketplace.reserveSlot(request.id, slotIndex)
    await marketplace.fillSlot(
      request.id, slotIndex, proof, request.ask.collateralPerSlot
    )
    check (await marketplace.getHost(request.id, slotIndex)) == some accounts[0]

  test "supports freeing a slot":
    await marketplace.requestStorage(request)
    await marketplace.reserveSlot(request.id, slotIndex)
    await marketplace.fillSlot(
      request.id, slotIndex, proof, request.ask.collateralPerSlot
    )
    await marketplace.freeSlot(slotId(request.id, slotIndex))
    check (await marketplace.getHost(request.id, slotIndex)) == none Address

  test "supports checking whether proof is required now":
    check (await marketplace.isProofRequired(slotId(request.id, slotIndex))) == false

  test "supports checking whether proof is required soon":
    check (await marketplace.willProofBeRequired(slotId(request.id, slotIndex))) == false

  test "submits proofs":
    await marketplace.requestStorage(request)
    await marketplace.reserveSlot(request.id, slotIndex)
    await marketplace.fillSlot(
      request.id, slotIndex, proof, request.ask.collateralPerSlot
    )
    await advanceToNextPeriod()
    await marketplace.submitProof(slotId(request.id, slotIndex), proof)

  test "marks a proof as missing":
    let slotId = slotId(request, slotIndex)
    await marketplace.requestStorage(request)
    await marketplace.reserveSlot(request.id, slotIndex)
    await marketplace.fillSlot(
      request.id, slotIndex, proof, request.ask.collateralPerSlot
    )
    await waitUntilProofRequired(slotId)
    let missingPeriod = periodicity.periodOf(await testbed.eth.time.now())
    await advanceToNextPeriod()
    await marketplace.markProofAsMissing(slotId, missingPeriod)
    check (await contract.missingProofs(slotId)) == 1

  test "can check whether a proof can be marked as missing":
    let slotId = slotId(request, slotIndex)
    await marketplace.requestStorage(request)
    await marketplace.reserveSlot(request.id, slotIndex)
    await marketplace.fillSlot(
      request.id, slotIndex, proof, request.ask.collateralPerSlot
    )
    await waitUntilProofRequired(slotId)
    let missingPeriod = periodicity.periodOf(await testbed.eth.time.now())
    await advanceToNextPeriod()
    check (await marketplace.canMarkProofAsMissing(slotId, missingPeriod)) == true

  test "can check whether a proof cannot be marked as missing when the slot is free":
    let slotId = slotId(request, slotIndex)
    await marketplace.requestStorage(request)
    await marketplace.reserveSlot(request.id, slotIndex)
    await marketplace.fillSlot(
      request.id, slotIndex, proof, request.ask.collateralPerSlot
    )
    await waitUntilProofRequired(slotId)

    await marketplace.freeSlot(slotId(request.id, slotIndex))

    let missingPeriod = periodicity.periodOf(await testbed.eth.time.now())
    await advanceToNextPeriod()
    check (await marketplace.canMarkProofAsMissing(slotId, missingPeriod)) == false

  test "can check whether a proof cannot be marked as missing before a proof is required":
    let slotId = slotId(request, slotIndex)
    await marketplace.requestStorage(request)
    await marketplace.reserveSlot(request.id, slotIndex)
    await marketplace.fillSlot(
      request.id, slotIndex, proof, request.ask.collateralPerSlot
    )

    let missingPeriod = periodicity.periodOf(await testbed.eth.time.now())
    await advanceToNextPeriod()
    check (await marketplace.canMarkProofAsMissing(slotId, missingPeriod)) == false

  test "can check whether a proof cannot be marked as missing if the proof was submitted":
    let slotId = slotId(request, slotIndex)
    await marketplace.requestStorage(request)
    await marketplace.reserveSlot(request.id, slotIndex)
    await marketplace.fillSlot(
      request.id, slotIndex, proof, request.ask.collateralPerSlot
    )
    await waitUntilProofRequired(slotId)

    await marketplace.submitProof(slotId(request.id, slotIndex), proof)

    let missingPeriod = periodicity.periodOf(await testbed.eth.time.now())
    await advanceToNextPeriod()
    check (await marketplace.canMarkProofAsMissing(slotId, missingPeriod)) == false

  test "supports slot filled subscriptions":
    await marketplace.requestStorage(request)
    var receivedIds: seq[RequestId]
    var receivedSlotIndices: seq[uint64]
    proc onSlotFilled(id: RequestId, slotIndex: uint64) =
      receivedIds.add(id)
      receivedSlotIndices.add(slotIndex)

    let subscription = await marketplace.subscribeSlotFilled(onSlotFilled)
    await marketplace.reserveSlot(request.id, slotIndex)
    await marketplace.fillSlot(
      request.id, slotIndex, proof, request.ask.collateralPerSlot
    )
    check eventually receivedIds == @[request.id] and receivedSlotIndices == @[
      slotIndex
    ]
    await subscription.unsubscribe()

  test "subscribes only to a certain slot":
    var otherSlot = slotIndex - 1
    await marketplace.requestStorage(request)
    var receivedSlotIndices: seq[uint64]
    proc onSlotFilled(requestId: RequestId, slotIndex: uint64) =
      receivedSlotIndices.add(slotIndex)

    let subscription =
      await marketplace.subscribeSlotFilled(request.id, slotIndex, onSlotFilled)
    await marketplace.reserveSlot(request.id, otherSlot)
    await marketplace.fillSlot(
      request.id, otherSlot, proof, request.ask.collateralPerSlot
    )
    await marketplace.reserveSlot(request.id, slotIndex)
    await marketplace.fillSlot(
      request.id, slotIndex, proof, request.ask.collateralPerSlot
    )
    check eventually receivedSlotIndices == @[slotIndex]
    await subscription.unsubscribe()

  test "supports slot freed subscriptions":
    await marketplace.requestStorage(request)
    await marketplace.reserveSlot(request.id, slotIndex)
    await marketplace.fillSlot(
      request.id, slotIndex, proof, request.ask.collateralPerSlot
    )
    var receivedRequestIds: seq[RequestId] = @[]
    var receivedIdxs: seq[uint64] = @[]
    proc onSlotFreed(requestId: RequestId, idx: uint64) =
      receivedRequestIds.add(requestId)
      receivedIdxs.add(idx)

    let subscription = await marketplace.subscribeSlotFreed(onSlotFreed)
    await marketplace.freeSlot(slotId(request.id, slotIndex))
    check eventually receivedRequestIds == @[request.id] and receivedIdxs == @[
      slotIndex
    ]
    await subscription.unsubscribe()

  test "supports slot reservations full subscriptions":
    let account2 = provider.getSigner(accounts[2])
    let account3 = provider.getSigner(accounts[3])

    await marketplace.requestStorage(request)

    var receivedRequestIds: seq[RequestId] = @[]
    var receivedIdxs: seq[uint64] = @[]
    proc onSlotReservationsFull(requestId: RequestId, idx: uint64) =
      receivedRequestIds.add(requestId)
      receivedIdxs.add(idx)

    let subscription =
      await marketplace.subscribeSlotReservationsFull(onSlotReservationsFull)

    await marketplace.reserveSlot(request.id, slotIndex)
    switchAccount(account2)
    await marketplace.reserveSlot(request.id, slotIndex)
    switchAccount(account3)
    await marketplace.reserveSlot(request.id, slotIndex)

    check eventually receivedRequestIds == @[request.id] and receivedIdxs == @[
      slotIndex
    ]
    await subscription.unsubscribe()

  test "support fulfillment subscriptions":
    await marketplace.requestStorage(request)
    var receivedIds: seq[RequestId]
    proc onFulfillment(id: RequestId) =
      receivedIds.add(id)

    let subscription = await marketplace.subscribeFulfillment(request.id, onFulfillment)
    for slotIndex in 0 ..< request.ask.slots:
      await marketplace.reserveSlot(request.id, slotIndex.uint64)
      await marketplace.fillSlot(
        request.id, slotIndex.uint64, proof, request.ask.collateralPerSlot
      )
    check eventually receivedIds == @[request.id]
    await subscription.unsubscribe()

  test "subscribes only to fulfillment of a certain request":
    var otherRequest = StorageRequest.example
    otherRequest.client = accounts[0]

    await marketplace.requestStorage(request)
    await marketplace.requestStorage(otherRequest)

    var receivedIds: seq[RequestId]
    proc onFulfillment(id: RequestId) =
      receivedIds.add(id)

    let subscription = await marketplace.subscribeFulfillment(request.id, onFulfillment)

    for slotIndex in 0 ..< request.ask.slots:
      await marketplace.reserveSlot(request.id, slotIndex.uint64)
      await marketplace.fillSlot(
        request.id, slotIndex.uint64, proof, request.ask.collateralPerSlot
      )
    for slotIndex in 0 ..< otherRequest.ask.slots:
      await marketplace.reserveSlot(otherRequest.id, slotIndex.uint64)
      await marketplace.fillSlot(
        otherRequest.id, slotIndex.uint64, proof, otherRequest.ask.collateralPerSlot
      )

    check eventually receivedIds == @[request.id]

    await subscription.unsubscribe()

  test "support request cancelled subscriptions":
    await marketplace.requestStorage(request)

    var receivedIds: seq[RequestId]
    proc onRequestCancelled(id: RequestId) =
      receivedIds.add(id)

    let subscription =
      await marketplace.subscribeRequestCancelled(request.id, onRequestCancelled)

    await advanceToCancelledRequest(request)
    await marketplace.withdrawFunds(request.id)
    check eventually receivedIds == @[request.id]
    await subscription.unsubscribe()

  test "support request failed subscriptions":
    await marketplace.requestStorage(request)

    var receivedIds: seq[RequestId]
    proc onRequestFailed(id: RequestId) =
      receivedIds.add(id)

    let subscription =
      await marketplace.subscribeRequestFailed(request.id, onRequestFailed)

    for slotIndex in 0 ..< request.ask.slots:
      await marketplace.reserveSlot(request.id, slotIndex.uint64)
      await marketplace.fillSlot(
        request.id, slotIndex.uint64, proof, request.ask.collateralPerSlot
      )
    for slotIndex in 0 .. request.ask.maxSlotLoss:
      let slotId = request.slotId(slotIndex.uint64)
      while true:
        let slotState = await marketplace.slotState(slotId)
        if slotState == SlotState.Repair or slotState == SlotState.Failed:
          break
        await waitUntilProofRequired(slotId)
        let missingPeriod = periodicity.periodOf(await testbed.eth.time.now())
        await advanceToNextPeriod()
        discard await contract.markProofAsMissing(slotId, missingPeriod).confirm(1)
    check eventually receivedIds == @[request.id]
    await subscription.unsubscribe()

  test "subscribes only to a certain request cancellation":
    var otherRequest = request
    otherRequest.nonce = Nonce.example
    await marketplace.requestStorage(request)
    await marketplace.requestStorage(otherRequest)

    var receivedIds: seq[RequestId]
    proc onRequestCancelled(requestId: RequestId) =
      receivedIds.add(requestId)

    let subscription =
      await marketplace.subscribeRequestCancelled(request.id, onRequestCancelled)
    await advanceToCancelledRequest(otherRequest) # shares expiry with otherRequest
    await marketplace.withdrawFunds(otherRequest.id)
    await marketplace.withdrawFunds(request.id)
    check eventually receivedIds == @[request.id]
    await subscription.unsubscribe()

  test "supports proof submission subscriptions":
    await marketplace.requestStorage(request)
    await marketplace.reserveSlot(request.id, slotIndex)
    await marketplace.fillSlot(
      request.id, slotIndex, proof, request.ask.collateralPerSlot
    )
    await advanceToNextPeriod()
    var receivedIds: seq[SlotId]
    proc onProofSubmission(id: SlotId) =
      receivedIds.add(id)

    let subscription = await marketplace.subscribeProofSubmission(onProofSubmission)
    await marketplace.submitProof(slotId(request.id, slotIndex), proof)
    check eventually receivedIds == @[slotId(request.id, slotIndex)]
    await subscription.unsubscribe()

  test "request is none when unknown":
    check isNone await marketplace.getRequest(request.id)

  test "can retrieve active requests":
    await marketplace.requestStorage(request)
    var request2 = StorageRequest.example
    request2.client = accounts[0]
    await marketplace.requestStorage(request2)
    check (await marketplace.myRequests()) == @[request.id, request2.id]

  test "retrieves correct request state when request is unknown":
    check (await marketplace.requestState(request.id)) == none RequestState

  test "can retrieve request state":
    await marketplace.requestStorage(request)
    for slotIndex in 0 ..< request.ask.slots:
      await marketplace.reserveSlot(request.id, slotIndex.uint64)
      await marketplace.fillSlot(
        request.id, slotIndex.uint64, proof, request.ask.collateralPerSlot
      )
    check (await marketplace.requestState(request.id)) == some RequestState.Started

  test "can retrieve active slots":
    await marketplace.requestStorage(request)
    await marketplace.reserveSlot(request.id, slotIndex - 1)
    await marketplace.fillSlot(
      request.id, slotIndex - 1, proof, request.ask.collateralPerSlot
    )
    await marketplace.reserveSlot(request.id, slotIndex)
    await marketplace.fillSlot(
      request.id, slotIndex, proof, request.ask.collateralPerSlot
    )
    let slotId1 = request.slotId(slotIndex - 1)
    let slotId2 = request.slotId(slotIndex)
    check (await marketplace.mySlots()) == @[slotId1, slotId2]

  test "returns none when slot is empty":
    await marketplace.requestStorage(request)
    let slotId = request.slotId(slotIndex)
    check (await marketplace.getActiveSlot(slotId)) == none Slot

  test "can retrieve request details from slot id":
    await marketplace.requestStorage(request)
    await marketplace.reserveSlot(request.id, slotIndex)
    await marketplace.fillSlot(
      request.id, slotIndex, proof, request.ask.collateralPerSlot
    )
    let slotId = request.slotId(slotIndex)
    let expected = Slot(request: request, slotIndex: slotIndex)
    check (await marketplace.getActiveSlot(slotId)) == some expected

  test "retrieves correct slot state when request is unknown":
    let slotId = request.slotId(slotIndex)
    check (await marketplace.slotState(slotId)) == SlotState.Free

  test "retrieves correct slot state once filled":
    await marketplace.requestStorage(request)
    await marketplace.reserveSlot(request.id, slotIndex)
    await marketplace.fillSlot(
      request.id, slotIndex, proof, request.ask.collateralPerSlot
    )
    let slotId = request.slotId(slotIndex)
    check (await marketplace.slotState(slotId)) == SlotState.Filled

  test "can query past StorageRequested events":
    var request1 = StorageRequest.example
    var request2 = StorageRequest.example
    request1.client = accounts[0]
    request2.client = accounts[0]
    await marketplace.requestStorage(request)
    await marketplace.requestStorage(request1)
    await marketplace.requestStorage(request2)

    # `marketplace.requestStorage` executes an `approve` tx before the
    # `requestStorage` tx, so that's two PoA blocks per `requestStorage` call (6
    # blocks for 3 calls). We don't need to check the `approve` for the first
    # `requestStorage` call, so we only need to check 5 "blocks ago". "blocks
    # ago".

    proc getsPastRequest(): Future[bool] {.async.} =
      let reqs = await marketplace.queryPastStorageRequestedEvents(blocksAgo = 5)
      reqs.mapIt(it.requestId) == @[request.id, request1.id, request2.id]

    check eventually await getsPastRequest()

  test "can query past SlotFilled events":
    await marketplace.requestStorage(request)
    await marketplace.reserveSlot(request.id, 0.uint64)
    await marketplace.reserveSlot(request.id, 1.uint64)
    await marketplace.reserveSlot(request.id, 2.uint64)
    await marketplace.fillSlot(
      request.id, 0.uint64, proof, request.ask.collateralPerSlot
    )
    await marketplace.fillSlot(
      request.id, 1.uint64, proof, request.ask.collateralPerSlot
    )
    await marketplace.fillSlot(
      request.id, 2.uint64, proof, request.ask.collateralPerSlot
    )

    # `marketplace.fill` executes an `approve` tx before the `fillSlot` tx, so that's
    # two PoA blocks per `fillSlot` call (6 blocks for 3 calls). We don't need
    # to check the `approve` for the first `fillSlot` call, so we only need to
    # check 5 "blocks ago".
    let events = await marketplace.queryPastSlotFilledEvents(blocksAgo = 5)
    check events ==
      @[
        SlotFilled(requestId: request.id, slotIndex: 0),
        SlotFilled(requestId: request.id, slotIndex: 1),
        SlotFilled(requestId: request.id, slotIndex: 2),
      ]

  test "can query past SlotFilled events since given timestamp":
    await marketplace.requestStorage(request)
    await marketplace.reserveSlot(request.id, 0.uint64)
    await marketplace.fillSlot(
      request.id, 0.uint64, proof, request.ask.collateralPerSlot
    )

    # The SlotFilled event will be included in the same block as
    # the fillSlot transaction. If we want to ignore the SlotFilled event
    # for this first slot, we need to jump to the next block and use the
    # timestamp of that block as our "fromTime" parameter to the
    # queryPastSlotFilledEvents function.
    await testbed.eth.time.advance(10)

    let (_, fromTime) = await provider.blockNumberAndTimestamp(BlockTag.latest)

    await testbed.eth.time.advance(1)

    await marketplace.reserveSlot(request.id, 1.uint64)
    await marketplace.reserveSlot(request.id, 2.uint64)
    await marketplace.fillSlot(
      request.id, 1.uint64, proof, request.ask.collateralPerSlot
    )
    await marketplace.fillSlot(
      request.id, 2.uint64, proof, request.ask.collateralPerSlot
    )

    let events = await marketplace.queryPastSlotFilledEvents(
      fromTime = fromTime.truncate(SecondsSince1970)
    )

    check events ==
      @[
        SlotFilled(requestId: request.id, slotIndex: 1),
        SlotFilled(requestId: request.id, slotIndex: 2),
      ]

  test "queryPastSlotFilledEvents returns empty sequence of events when " &
    "no SlotFilled events have occurred since given timestamp":
    await marketplace.requestStorage(request)
    await marketplace.reserveSlot(request.id, 0.uint64)
    await marketplace.reserveSlot(request.id, 1.uint64)
    await marketplace.reserveSlot(request.id, 2.uint64)
    await marketplace.fillSlot(
      request.id, 0.uint64, proof, request.ask.collateralPerSlot
    )
    await marketplace.fillSlot(
      request.id, 1.uint64, proof, request.ask.collateralPerSlot
    )
    await marketplace.fillSlot(
      request.id, 2.uint64, proof, request.ask.collateralPerSlot
    )

    await testbed.eth.time.advance(10)

    let (_, fromTime) = await provider.blockNumberAndTimestamp(BlockTag.latest)

    let events = await marketplace.queryPastSlotFilledEvents(
      fromTime = fromTime.truncate(SecondsSince1970)
    )

    check events.len == 0

  test "past event query can specify negative `blocksAgo` parameter":
    await marketplace.requestStorage(request)

    check eventually (
      (await marketplace.queryPastStorageRequestedEvents(blocksAgo = -2)) ==
      (await marketplace.queryPastStorageRequestedEvents(blocksAgo = 2))
    )

  test "pays rewards and returns collateral to host":
    await marketplace.requestStorage(request)

    let address = await host.getAddress()
    switchAccount(host)
    await marketplace.reserveSlot(request.id, 0.uint64)
    await marketplace.fillSlot(
      request.id, 0.uint64, proof, request.ask.collateralPerSlot
    )
    let filledAt = await testbed.eth.time.blockTime(BlockTag.latest)

    for slotIndex in 1 ..< request.ask.slots:
      await marketplace.reserveSlot(request.id, slotIndex.uint64)
      await marketplace.fillSlot(
        request.id, slotIndex.uint64, proof, request.ask.collateralPerSlot
      )

    let requestEnd = (await marketplace.getRequestEnd(request.id)).uint64
    await testbed.eth.time.advanceTo(requestEnd + 1)

    let startBalance = await token.balanceOf(address)
    await marketplace.freeSlot(request.slotId(0.uint64))
    let endBalance = await token.balanceOf(address)

    let expectedPayout = request.expectedPayout(filledAt, requestEnd)
    check endBalance == (startBalance + expectedPayout + request.ask.collateralPerSlot)

  test "pays rewards to reward recipient, collateral to host":
    marketplace = OnChainMarketplace.new(contract, hostRewardRecipient.some)
    let hostAddress = await host.getAddress()

    await marketplace.requestStorage(request)

    switchAccount(host)
    await marketplace.reserveSlot(request.id, 0.uint64)
    await marketplace.fillSlot(
      request.id, 0.uint64, proof, request.ask.collateralPerSlot
    )
    let filledAt = await testbed.eth.time.blockTime(BlockTag.latest)

    for slotIndex in 1 ..< request.ask.slots:
      await marketplace.reserveSlot(request.id, slotIndex.uint64)
      await marketplace.fillSlot(
        request.id, slotIndex.uint64, proof, request.ask.collateralPerSlot
      )

    let requestEnd = (await marketplace.getRequestEnd(request.id)).uint64
    await testbed.eth.time.advanceTo(requestEnd + 1)

    let startBalanceHost = await token.balanceOf(hostAddress)
    let startBalanceReward = await token.balanceOf(hostRewardRecipient)

    await marketplace.freeSlot(request.slotId(0.uint64))

    let endBalanceHost = await token.balanceOf(hostAddress)
    let endBalanceReward = await token.balanceOf(hostRewardRecipient)

    let expectedPayout = request.expectedPayout(filledAt, requestEnd)
    check endBalanceHost == (startBalanceHost + request.ask.collateralPerSlot)
    check endBalanceReward == (startBalanceReward + expectedPayout)

  test "returns the collateral when the slot is not being repaired":
    await marketplace.requestStorage(request)
    await marketplace.reserveSlot(request.id, 0.uint64)
    await marketplace.fillSlot(
      request.id, 0.uint64, proof, request.ask.collateralPerSlot
    )

    let slotId = request.slotId(0.uint64)
    without collateral =? await marketplace.slotCollateral(request.id, 0.uint64), error:
      fail()

    check collateral == request.ask.collateralPerSlot

  test "calculates correctly the collateral when the slot is being repaired":
    # Ensure that the config is loaded and repairRewardPercentage is available
    discard await marketplace.repairRewardPercentage()

    await marketplace.requestStorage(request)
    await marketplace.reserveSlot(request.id, 0.uint64)
    await marketplace.fillSlot(
      request.id, 0.uint64, proof, request.ask.collateralPerSlot
    )
    await marketplace.freeSlot(slotId(request.id, 0.uint64))

    let slotId = request.slotId(0.uint64)

    without collateral =? await marketplace.slotCollateral(request.id, 0.uint64), error:
      fail()

    # slotCollateral
    # repairRewardPercentage = 10
    # expected collateral = slotCollateral - slotCollateral * 0.1
    check collateral ==
      request.ask.collateralPerSlot - (request.ask.collateralPerSlot * 10).div(100.u256)

  test "the request is added to cache after the first access":
    await marketplace.requestStorage(request)

    check marketplace.requestCache.contains($request.id) == false
    discard await marketplace.getRequest(request.id)

    check marketplace.requestCache.contains($request.id) == true
    let cacheValue = marketplace.requestCache[$request.id]
    check cacheValue == request
