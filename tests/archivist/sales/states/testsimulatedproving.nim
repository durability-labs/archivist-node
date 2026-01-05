import pkg/chronos
import pkg/questionable
import pkg/archivist/contracts/requests
import pkg/archivist/sales/states/provingsimulated
import pkg/archivist/sales/states/proving
import pkg/archivist/sales/states/cancelled
import pkg/archivist/sales/states/failed
import pkg/archivist/sales/states/payout
import pkg/archivist/sales/salesagent
import pkg/archivist/sales/salescontext

import ../../../asynctest
import ../../examples
import ../../helpers
import ../../helpers/mockmarketplace
import ../../helpers/mockclock
import ../mockstorage

asyncchecksuite "sales state 'simulated-proving'":
  let slot = Slot.example
  let request = slot.request
  let proof = Groth16Proof.example
  let failEveryNProofs = 3
  let totalProofs = 6

  var marketplace: MockMarketplace
  var storage: MockStorage
  var clock: MockClock
  var agent: SalesAgent
  var state: SaleProvingSimulated

  var proofSubmitted: Future[void] = newFuture[void]("proofSubmitted")
  var subscription: Subscription

  setup:
    clock = MockClock.new()
    storage = MockStorage.new()

    proc onProofSubmission(id: SlotId) =
      proofSubmitted.complete()
      proofSubmitted = newFuture[void]("proofSubmitted")

    marketplace = MockMarketplace.new()
    marketplace.slotState[slot.id] = SlotState.Filled
    marketplace.setProofRequired(slot.id, true)
    subscription = await marketplace.subscribeProofSubmission(onProofSubmission)

    let context = SalesContext(marketplace: marketplace, storage: storage, clock: clock)
    agent = newSalesAgent(context, request.id, slot.slotIndex, request.some)
    state = SaleProvingSimulated.new()
    state.failEveryNProofs = failEveryNProofs

  teardown:
    await subscription.unsubscribe()

  proc advanceToNextPeriod(marketplace: AbstractMarketplace) {.async.} =
    let periodicity = await marketplace.periodicity()
    let current = periodicity.periodOf(clock.now().Timestamp)
    let periodEnd = periodicity.periodEnd(current)
    clock.set(periodEnd.toSecondsSince1970 + 1)

  proc waitForProvingRounds(marketplace: AbstractMarketplace, rounds: int) {.async.} =
    var rnds = rounds - 1 # proof round runs prior to advancing
    while rnds > 0:
      await marketplace.advanceToNextPeriod()
      await proofSubmitted
      rnds -= 1

  test "switches to cancelled state when request expires":
    let next = state.onCancelled(request)
    check !next of SaleCancelled

  test "switches to failed state when request fails":
    let next = state.onFailed(request)
    check !next of SaleFailed

  test "submits invalid proof every 3 proofs":
    storage.proveSlotResult = success(proof)
    let future = state.run(agent)
    let invalid = Groth16Proof.default

    await marketplace.waitForProvingRounds(totalProofs)
    check marketplace.submitted == @[proof, proof, invalid, proof, proof, invalid]

    await future.cancelAndWait()

  test "switches to payout state when request is finished":
    marketplace.slotState[slot.id] = SlotState.Filled

    let future = state.run(agent)

    marketplace.slotState[slot.id] = SlotState.Finished
    await marketplace.advanceToNextPeriod()

    check eventually future.finished
    check !(future.read()) of SalePayout
