import std/times
import pkg/chronos
import pkg/archivist/marketplace/sales
import pkg/archivist/marketplace/sales/salesagent
import pkg/archivist/marketplace/sales/salescontext
import pkg/archivist/marketplace/sales/statemachine

import ../../../asynctest
import ../../helpers/mockmarketplace
import ../../helpers/mockclock
import ../../helpers
import ../../examples

var onCancelCalled = false
var onFailedCalled = false
var onSlotFilledCalled = false

type MockState = ref object of SaleState

method `$`*(state: MockState): string =
  "MockState"

method onCancelled*(state: MockState, request: StorageRequest): ?State =
  onCancelCalled = true

method onFailed*(state: MockState, request: StorageRequest): ?State =
  onFailedCalled = true

method onSlotFilled*(
    state: MockState, requestId: RequestId, slotIndex: uint64
): ?State =
  onSlotFilledCalled = true

asyncchecksuite "Sales agent":
  let request = StorageRequest.example
  let slot = Slot(request: request, slotIndex: 0)
  var agent: SalesAgent
  var context: SalesContext
  var marketplace: MockMarketplace
  var clock: MockClock

  setup:
    marketplace = MockMarketplace.new()
    marketplace.requested = @[request]
    marketplace.requestExpiry[request.id] =
      StorageTimestamp.init(getTime().toUnix()) + request.expiry
    clock = MockClock.new()
    context = SalesContext(marketplace: marketplace, clock: clock)
    onCancelCalled = false
    onFailedCalled = false
    onSlotFilledCalled = false
    agent = newSalesAgent(context, SlotInfo.init(slot.request.id, slot.slotIndex))

  teardown:
    await agent.stop()

  test "can retrieve slot":
    check agent.data.slotInfo.slot.isNone
    await agent.retrieveSlot()
    check agent.data.slotInfo.slot == some slot

  test "subscribeCancellation assigns cancelled future":
    await agent.retrieveSlot()
    await agent.subscribeCancellation()
    check not agent.data.cancelled.isNil

  test "unsubscribeCancellation unassigns cancelled future":
    await agent.retrieveSlot()
    await agent.subscribeCancellation()
    await agent.unsubscribeCancellation()
    check agent.data.cancelled.isNil

  test "subscribeCancellation can be called multiple times, without overwriting subscriptions/futures":
    await agent.retrieveSlot()
    await agent.subscribeCancellation()
    let cancelled = agent.data.cancelled
    await agent.subscribeCancellation()
    check cancelled == agent.data.cancelled

  test "unsubscribeCancellation can be called multiple times":
    await agent.retrieveSlot()
    await agent.subscribeCancellation()
    await agent.unsubscribeCancellation()
    await agent.unsubscribeCancellation()

  test "current state onCancelled called when request is cancelled":
    agent.start(MockState.new())
    await agent.retrieveSlot()
    await agent.subscribeCancellation()
    marketplace.requestState[request.id] = RequestState.Cancelled
    clock.set(marketplace.requestExpiry[request.id].toSecondsSince1970 + 1)
    check eventually onCancelCalled

  for requestState in {
    RequestState.New, RequestState.Started, RequestState.Finished, RequestState.Failed
  }:
    test "onCancelled is not called when request state is " & $requestState:
      agent.start(MockState.new())
      await agent.retrieveSlot()
      await agent.subscribeCancellation()
      marketplace.requestState[request.id] = requestState
      clock.set(marketplace.requestExpiry[request.id].toSecondsSince1970 + 1)
      await sleepAsync(100.millis)
      check not onCancelCalled

  for requestState in {RequestState.Started, RequestState.Finished, RequestState.Failed}:
    test "cancelled future is finished when request state is " & $requestState:
      agent.start(MockState.new())
      await agent.retrieveSlot()
      await agent.subscribeCancellation()
      marketplace.requestState[request.id] = requestState
      clock.set(marketplace.requestExpiry[request.id].toSecondsSince1970 + 1)
      check eventually agent.data.cancelled.finished

  test "cancelled future is finished (cancelled) when onFulfilled called":
    agent.start(MockState.new())
    await agent.retrieveSlot()
    await agent.subscribeCancellation()
    agent.onFulfilled(request.id)
    # Note: futures that are cancelled, and do not re-raise the CancelledError
    # will have a state of completed, not cancelled.
    check eventually agent.data.cancelled.completed()

  test "current state onFailed called when onFailed called":
    agent.start(MockState.new())
    await agent.retrieveSlot()
    agent.onFailed(request.id)
    check eventually onFailedCalled

  test "current state onSlotFilled called when slot filled emitted":
    agent.start(MockState.new())
    await agent.retrieveSlot()
    agent.onSlotFilled(request.id, slot.slotIndex)
    check eventually onSlotFilledCalled
