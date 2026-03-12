import pkg/questionable
import pkg/chronos
import pkg/archivist/marketplace/contracts/requests
import pkg/archivist/marketplace/sales/states/initialproving
import pkg/archivist/marketplace/sales/states/cancelled
import pkg/archivist/marketplace/sales/states/failed
import pkg/archivist/marketplace/sales/states/filling
import pkg/archivist/marketplace/sales/states/types
import pkg/archivist/marketplace/sales/salesagent
import pkg/archivist/marketplace/sales/salescontext
import pkg/archivist/marketplace/abstractmarketplace

import ../../../../asynctest
import ../../../examples
import ../../../helpers
import ../../../helpers/mockmarketplace
import ../../../helpers/mockclock
import ../mockstorage
import ../helpers/periods

asyncchecksuite "sales state 'initialproving'":
  let proof = Groth16Proof.example
  let request = StorageRequest.example
  let slotIndex = request.ask.slots div 2

  var state: SaleInitialProving
  var agent: SalesAgent
  var marketplace: MockMarketplace
  var storage: MockStorage
  var clock: MockClock

  setup:
    marketplace = MockMarketplace.new()
    storage = MockStorage.new()
    clock = MockClock.new()
    let context = SalesContext(marketplace: marketplace, storage: storage, clock: clock)
    agent = newSalesAgent(context, request.id, slotIndex, request.some)
    state = SaleInitialProving.new()

  proc allowProofToStart() {.async.} =
    # it won't start proving until the next period
    await clock.advanceToNextPeriod(marketplace)

  test "switches to cancelled state when request expires":
    let next = state.onCancelled(request)
    check !next of SaleCancelled

  test "switches to failed state when request fails":
    let next = state.onFailed(request)
    check !next of SaleFailed

  test "waits for the beginning of the period to get the challenge":
    let future = state.run(agent)
    check eventually clock.isWaiting
    check not future.finished
    await allowProofToStart()
    discard await future

  test "waits another period when the proof pointer is about to wrap around":
    marketplace.proofPointer = 250
    let future = state.run(agent)
    await allowProofToStart()
    check eventually clock.isWaiting
    check not future.finished
    marketplace.proofPointer = 100
    await allowProofToStart()
    discard await future

  test "provides proof challenge to prover":
    marketplace.proofChallenge = ProofChallenge.example

    let future = state.run(agent)
    await allowProofToStart()

    discard await future

    check storage.proveSlotCalls.len == 1
    let (_, _, challenge) = storage.proveSlotCalls[0]
    check challenge == marketplace.proofChallenge

  test "switches to filling state when initial proving is complete":
    storage.proveSlotResult = success(proof)

    let future = state.run(agent)
    await allowProofToStart()
    let next = await future

    check !next of SaleFilling
    check SaleFilling(!next).proof == proof

  test "switches to errored state when proving fails":
    storage.proveSlotResult = Groth16Proof.failure("oh no!")

    let future = state.run(agent)
    await allowProofToStart()
    let next = await future

    check !next of SaleErrored
