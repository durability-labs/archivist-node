import pkg/chronos
import pkg/questionable
import pkg/archivist/contracts/requests
import pkg/archivist/sales/states/proving
import pkg/archivist/sales/states/cancelled
import pkg/archivist/sales/states/failed
import pkg/archivist/sales/states/payout
import pkg/archivist/sales/states/errored
import pkg/archivist/sales/salesagent
import pkg/archivist/sales/salescontext

import ../../../asynctest
import ../../examples
import ../../helpers
import ../../helpers/mockmarketplace
import ../../helpers/mockclock

asyncchecksuite "sales state 'proving'":
  let slot = Slot.example
  let request = slot.request
  let proof = Groth16Proof.example

  var marketplace: MockMarketplace
  var clock: MockClock
  var agent: SalesAgent
  var state: SaleProving
  var receivedChallenge: ProofChallenge

  setup:
    clock = MockClock.new()
    marketplace = MockMarketplace.new()
    let onProve = proc(
        slot: Slot, challenge: ProofChallenge, period: Period
    ): Future[?!Groth16Proof] {.async: (raises: [CancelledError]).} =
      receivedChallenge = challenge
      return success(proof)
    let context =
      SalesContext(marketplace: marketplace, clock: clock, onProve: onProve.some)
    agent = newSalesAgent(context, request.id, slot.slotIndex, request.some)
    state = SaleProving.new()

  proc advanceToNextPeriod(marketplace: AbstractMarketplace) {.async.} =
    let periodicity = await marketplace.periodicity()
    let current = periodicity.periodOf(clock.now().Timestamp)
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

  test "onProve callback provides proof challenge":
    marketplace.proofChallenge = ProofChallenge.example
    marketplace.slotState[slot.id] = SlotState.Filled
    marketplace.setProofRequired(slot.id, true)

    let future = state.run(agent)

    check eventually receivedChallenge == marketplace.proofChallenge

    await future.cancelAndWait()
