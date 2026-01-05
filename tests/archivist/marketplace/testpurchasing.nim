import std/times
import pkg/chronos
import pkg/stint
import pkg/archivist/marketplace/purchasing
import pkg/archivist/marketplace/purchasing/purchase
import pkg/archivist/marketplace/purchasing/states/finished
import pkg/archivist/marketplace/purchasing/states/started
import pkg/archivist/marketplace/purchasing/states/submitted
import pkg/archivist/marketplace/purchasing/states/unknown
import pkg/archivist/marketplace/purchasing/states/cancelled
import pkg/archivist/marketplace/purchasing/states/failed

import ../../asynctest
import ../helpers/mockmarketplace
import ../helpers/mockclock
import ../examples
import ../helpers

asyncchecksuite "Purchasing":
  var purchasing: Purchasing
  var marketplace: MockMarketplace
  var clock: MockClock
  var request, populatedRequest: StorageRequest

  setup:
    marketplace = MockMarketplace.new()
    clock = MockClock.new()
    purchasing = Purchasing.new(marketplace, clock)
    request = StorageRequest(
      ask: StorageAsk(
        slots: uint8.example.uint64,
        slotSize: uint32.example.uint64,
        duration: uint16.example.uint64,
        pricePerBytePerSecond: uint8.example.u256,
      )
    )

    # We need request which has stable ID during the whole Purchasing pipeline
    # for some tests (related to expiry). Because of Purchasing.populate() we need
    # to do the steps bellow.
    populatedRequest = StorageRequest.example
    populatedRequest.client = await marketplace.getSigner()

  test "submits a storage request when asked":
    discard !await purchasing.purchase(request)
    check eventually marketplace.requested.len > 0
    check marketplace.requested[0].ask.slots == request.ask.slots
    check marketplace.requested[0].ask.slotSize == request.ask.slotSize
    check marketplace.requested[0].ask.duration == request.ask.duration
    check marketplace.requested[0].ask.pricePerBytePerSecond ==
      request.ask.pricePerBytePerSecond

  test "remembers purchases":
    let purchase1 = !await purchasing.purchase(request)
    let purchase2 = !await purchasing.purchase(request)
    check purchasing.getPurchase(purchase1.id) == some purchase1
    check purchasing.getPurchase(purchase2.id) == some purchase2

  test "has a default value for proof probability":
    check purchasing.proofProbability != 0.u256

  test "can change default value for proof probability":
    purchasing.proofProbability = 42.u256
    discard !await purchasing.purchase(request)
    check eventually marketplace.requested.len > 0
    check marketplace.requested[0].ask.proofProbability == 42.u256

  test "can override proof probability per request":
    request.ask.proofProbability = 42.u256
    discard !await purchasing.purchase(request)
    check eventually marketplace.requested.len > 0
    check marketplace.requested[0].ask.proofProbability == 42.u256

  test "includes a random nonce in every storage request":
    discard !await purchasing.purchase(request)
    discard !await purchasing.purchase(request)
    check eventually marketplace.requested.len > 0
    check marketplace.requested[0].nonce != marketplace.requested[1].nonce

  test "sets client address in request":
    discard !await purchasing.purchase(request)
    check eventually marketplace.requested.len > 0
    check marketplace.requested[0].client == await marketplace.getSigner()

  test "succeeds when request is finished":
    marketplace.requestExpiry[populatedRequest.id] = getTime().toUnix() + 10
    let purchase = !await purchasing.purchase(populatedRequest)

    check eventually marketplace.requested.len > 0
    let request = marketplace.requested[0]
    let requestEnd = getTime().toUnix() + 42
    marketplace.requestEnds[request.id] = requestEnd

    marketplace.emitRequestFulfilled(request.id)
    clock.set(requestEnd + 1)
    await purchase.wait()
    check purchase.error.isNone

  test "fails when request times out":
    let purchase = !await purchasing.purchase(populatedRequest)
    check eventually marketplace.requested.len > 0

    let expiry = marketplace.requestExpiry[populatedRequest.id]
    clock.set(expiry + 1)
    expect PurchaseTimeout:
      await purchase.wait()

  test "checks that funds were withdrawn when purchase times out":
    let purchase = !await purchasing.purchase(populatedRequest)
    check eventually marketplace.requested.len > 0
    let request = marketplace.requested[0]
    let expiry = marketplace.requestExpiry[populatedRequest.id]
    clock.set(expiry + 1)
    expect PurchaseTimeout:
      await purchase.wait()
    check marketplace.withdrawn == @[request.id]

suite "Purchasing state machine":
  var purchasing: Purchasing
  var marketplace: MockMarketplace
  var clock: MockClock
  var request: StorageRequest

  setup:
    marketplace = MockMarketplace.new()
    clock = MockClock.new()
    purchasing = Purchasing.new(marketplace, clock)
    request = StorageRequest(
      ask: StorageAsk(
        slots: uint8.example.uint64,
        slotSize: uint32.example.uint64,
        duration: uint16.example.uint64,
        pricePerBytePerSecond: uint8.example.u256,
      )
    )

  test "loads active purchases from marketplace":
    let me = await marketplace.getSigner()
    let request1, request2, request3 = StorageRequest.example
    marketplace.requested = @[request1, request2, request3]
    marketplace.activeRequests[me] = @[request1.id, request2.id]
    await purchasing.load()
    check isSome purchasing.getPurchase(PurchaseId(request1.id))
    check isSome purchasing.getPurchase(PurchaseId(request2.id))
    check isNone purchasing.getPurchase(PurchaseId(request3.id))

  test "loads correct purchase.future state for purchases from marketplace":
    let me = await marketplace.getSigner()
    let request1, request2, request3, request4, request5 = StorageRequest.example
    marketplace.requested = @[request1, request2, request3, request4, request5]
    marketplace.activeRequests[me] =
      @[request1.id, request2.id, request3.id, request4.id, request5.id]
    marketplace.requestState[request1.id] = RequestState.New
    marketplace.requestState[request2.id] = RequestState.Started
    marketplace.requestState[request3.id] = RequestState.Cancelled
    marketplace.requestState[request4.id] = RequestState.Finished
    marketplace.requestState[request5.id] = RequestState.Failed

    # ensure the started state doesn't error, giving a false positive test result
    marketplace.requestEnds[request2.id] = clock.now() - 1

    await purchasing.load()
    check eventually purchasing.getPurchase(PurchaseId(request1.id)) .? finished ==
      false.some
    check eventually purchasing.getPurchase(PurchaseId(request2.id)) .? finished ==
      true.some
    check eventually purchasing.getPurchase(PurchaseId(request3.id)) .? finished ==
      true.some
    check eventually purchasing.getPurchase(PurchaseId(request4.id)) .? finished ==
      true.some
    check eventually purchasing.getPurchase(PurchaseId(request5.id)) .? finished ==
      true.some
    check eventually purchasing.getPurchase(PurchaseId(request5.id)) .? error.isSome

  test "moves to PurchaseSubmitted when request state is New":
    let request = StorageRequest.example
    let purchase = Purchase.new(request, marketplace, clock)
    marketplace.requested = @[request]
    marketplace.requestState[request.id] = RequestState.New
    let next = await PurchaseUnknown().run(purchase)
    check !next of PurchaseSubmitted

  test "moves to PurchaseStarted when request state is Started":
    let request = StorageRequest.example
    let purchase = Purchase.new(request, marketplace, clock)
    marketplace.requestEnds[request.id] = clock.now() + request.ask.duration.int64
    marketplace.requested = @[request]
    marketplace.requestState[request.id] = RequestState.Started
    let next = await PurchaseUnknown().run(purchase)
    check !next of PurchaseStarted

  test "moves to PurchaseCancelled when request state is Cancelled":
    let request = StorageRequest.example
    let purchase = Purchase.new(request, marketplace, clock)
    marketplace.requested = @[request]
    marketplace.requestState[request.id] = RequestState.Cancelled
    let next = await PurchaseUnknown().run(purchase)
    check !next of PurchaseCancelled

  test "moves to PurchaseFinished when request state is Finished":
    let request = StorageRequest.example
    let purchase = Purchase.new(request, marketplace, clock)
    marketplace.requested = @[request]
    marketplace.requestState[request.id] = RequestState.Finished
    let next = await PurchaseUnknown().run(purchase)
    check !next of PurchaseFinished

  test "moves to PurchaseFailed when request state is Failed":
    let request = StorageRequest.example
    let purchase = Purchase.new(request, marketplace, clock)
    marketplace.requested = @[request]
    marketplace.requestState[request.id] = RequestState.Failed
    let next = await PurchaseUnknown().run(purchase)
    check !next of PurchaseFailed

  test "moves to PurchaseFailed state once RequestFailed emitted":
    let request = StorageRequest.example
    let purchase = Purchase.new(request, marketplace, clock)
    marketplace.requestEnds[request.id] = clock.now() + request.ask.duration.int64
    let future = PurchaseStarted().run(purchase)

    marketplace.emitRequestFailed(request.id)

    let next = await future
    check !next of PurchaseFailed

  test "moves to PurchaseFinished state once request finishes":
    let request = StorageRequest.example
    let purchase = Purchase.new(request, marketplace, clock)
    marketplace.requestEnds[request.id] = clock.now() + request.ask.duration.int64
    let future = PurchaseStarted().run(purchase)

    clock.advance(request.ask.duration.int64 + 1)

    let next = await future
    check !next of PurchaseFinished

  test "withdraw funds in PurchaseFinished":
    let request = StorageRequest.example
    let purchase = Purchase.new(request, marketplace, clock)
    discard await PurchaseFinished().run(purchase)
    check request.id in marketplace.withdrawn

  test "withdraw funds in PurchaseFailed":
    let request = StorageRequest.example
    let purchase = Purchase.new(request, marketplace, clock)
    discard await PurchaseFailed().run(purchase)
    check request.id in marketplace.withdrawn

  test "withdraw funds in PurchaseCancelled":
    let request = StorageRequest.example
    let purchase = Purchase.new(request, marketplace, clock)
    discard await PurchaseCancelled().run(purchase)
    check request.id in marketplace.withdrawn
