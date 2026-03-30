import pkg/chronos
import pkg/questionable
import pkg/archivist/marketplace/contracts/requests
import pkg/archivist/marketplace/sales/states/proving
import pkg/archivist/marketplace/sales/states/cancelled
import pkg/archivist/marketplace/sales/states/failed
import pkg/archivist/marketplace/sales/states/payout
import pkg/archivist/marketplace/sales/states/types
import pkg/archivist/marketplace/sales/salesagent
import pkg/archivist/marketplace/sales/salescontext

import ../../../../asynctest
import ../../../examples
import ../../../helpers
import ../../../helpers/mockmarketplace
import ../../../helpers/mockclock
import ../mockstorage

asyncchecksuite "sales state 'proving'":
  let slot = Slot.example
  let request = slot.request

  var marketplace: MockMarketplace
  var storage: MockStorage
  var clock: MockClock
  var agent: SalesAgent
  var state: SaleProving

  setup:
    clock = MockClock.new()
    marketplace = MockMarketplace.new()
    storage = MockStorage.new()
    let context = SalesContext(marketplace: marketplace, storage: storage, clock: clock)
    agent = newSalesAgent(context, request.id, slot.slotIndex, request.some)
    state = SaleProving.new()

  proc advanceToNextPeriod(marketplace: AbstractMarketplace) {.async.} =
    let periodicity = marketplace.periodicity()
    let current = periodicity.periodOf(clock.now())
    let periodEnd = periodicity.periodEnd(current)
    clock.set(periodEnd.toSecondsSince1970 + 1)

  test "switches to cancelled state when request expires":
    let next = state.onCancelled(request)
    check !next of SaleCancelled

  test "switches to failed state when request fails":
    let next = state.onFailed(request)
    check !next of SaleFailed

  test "submits proofs":
    var receivedIds: seq[SlotId]

    proc onProofSubmission(id: SlotId) =
      receivedIds.add(id)

    let subscription = await marketplace.subscribeProofSubmission(onProofSubmission)
    marketplace.slotState[slot.id] = SlotState.Filled

    let future = state.run(agent)

    marketplace.setProofRequired(slot.id, true)
    await marketplace.advanceToNextPeriod()

    check eventually receivedIds.contains(slot.id)

    await future.cancelAndWait()
    await subscription.unsubscribe()

  test "switches to payout state when request is finished":
    marketplace.slotState[slot.id] = SlotState.Filled

    let future = state.run(agent)

    marketplace.slotState[slot.id] = SlotState.Finished
    await marketplace.advanceToNextPeriod()

    check eventually future.finished
    check !(future.read()) of SalePayout

  test "switches to error state when slot is no longer filled":
    marketplace.slotState[slot.id] = SlotState.Filled

    let future = state.run(agent)

    marketplace.slotState[slot.id] = SlotState.Free
    await marketplace.advanceToNextPeriod()

    check eventually future.finished
    check !(future.read()) of SaleErrored

  test "provides proof challenge to prover":
    marketplace.proofChallenge = ProofChallenge.example
    marketplace.slotState[slot.id] = SlotState.Filled
    marketplace.setProofRequired(slot.id, true)

    let future = state.run(agent)

    check eventually storage.proveSlotCalls.len == 1
    let (_, _, challenge) = storage.proveSlotCalls[0]
    check challenge == marketplace.proofChallenge

    await future.cancelAndWait()

  test "continues proving loop after proof generation timeout":
    marketplace.slotState[slot.id] = SlotState.Filled
    marketplace.setProofRequired(slot.id, true)
    storage.proveSlotShouldHang = true

    let future = state.run(agent)
    await marketplace.advanceToNextPeriod()

    # Wait for the proving loop to enter proveSlot and register the timeout
    check eventually storage.proveSlotCalls.len == 1

    # Advance clock past periodEnd to trigger clock-based timeout
    let periodicity = marketplace.periodicity()
    let provingPeriod = periodicity.periodOf(clock.now())
    let periodEnd = periodicity.periodEnd(provingPeriod)
    clock.set(periodEnd.toSecondsSince1970 + 1)

    # Loop should survive the timeout and wait for next period.
    # Finish the slot so the loop exits cleanly.
    storage.proveSlotShouldHang = false
    marketplace.setProofRequired(slot.id, false)
    marketplace.slotState[slot.id] = SlotState.Finished
    await marketplace.advanceToNextPeriod()

    check eventually future.finished
    check !(future.read()) of SalePayout
