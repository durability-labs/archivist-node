import pkg/questionable
import pkg/chronos
import pkg/archivist/marketplace/contracts/requests
import pkg/archivist/marketplace/sales/states/cancelled
import pkg/archivist/marketplace/sales/states/types
import pkg/archivist/marketplace/sales/salesagent
import pkg/archivist/marketplace/sales/salescontext
import pkg/archivist/marketplace/abstractmarketplace
from pkg/archivist/utils/asyncstatemachine import State

import ../../../../asynctest
import ../../../examples
import ../../../helpers
import ../../../helpers/mockmarketplace
import ../../../helpers/mockclock

asyncchecksuite "sales state 'cancelled'":
  let request = StorageRequest.example
  let slotIndex = request.ask.slots div 2
  let slot = Slot(request: request, slotIndex: slotIndex)
  let clock = MockClock.new()

  let collateral = Tokens.example

  var marketplace: MockMarketplace
  var state: SaleCancelled
  var agent: SalesAgent
  var reprocessSlotWas: ?bool

  setup:
    marketplace = MockMarketplace.new()
    let onCleanUp = proc(reprocessSlot = false) {.async: (raises: []).} =
      reprocessSlotWas = some reprocessSlot

    let context = SalesContext(marketplace: marketplace, clock: clock)
    agent = newSalesAgent(context, SlotInfo.init(slot.id))
    agent.onCleanUp = onCleanUp
    state = SaleCancelled.new()
    reprocessSlotWas = bool.none

  teardown:
    reprocessSlotWas = bool.none

  test "calls onCleanUp with reprocessSlot = true":
    marketplace.fillSlot(
      requestId = request.id,
      slotIndex = slotIndex,
      proof = Groth16Proof.default,
      host = await marketplace.getSigner(),
      collateral = collateral,
    )
    discard await state.run(agent)
    check eventually reprocessSlotWas == some false

  test "completes the cancelled state when free slot error is raised when a host is hosting a slot":
    marketplace.fillSlot(
      requestId = request.id,
      slotIndex = slotIndex,
      proof = Groth16Proof.default,
      host = await marketplace.getSigner(),
      collateral = collateral,
    )

    let error =
      newException(SlotStateMismatchError, "Failed to free slot, slot is already free")
    marketplace.setErrorOnFreeSlot(error)

    let next = await state.run(agent)
    check next == none State
    check eventually reprocessSlotWas == some false

  test "completes the cancelled state when free slot error is raised when a host is not hosting a slot":
    discard marketplace.reserveSlot(requestId = request.id, slotIndex = slotIndex)
    marketplace.fillSlot(
      requestId = request.id,
      slotIndex = slotIndex,
      proof = Groth16Proof.default,
      host = Address.example,
      collateral = collateral,
    )

    let error =
      newException(SlotStateMismatchError, "Failed to free slot, slot is already free")
    marketplace.setErrorOnFreeSlot(error)

    let next = await state.run(agent)
    check next == none State
    check eventually reprocessSlotWas == some false

  test "calls onCleanUp when an error is raised":
    marketplace.fillSlot(
      requestId = request.id,
      slotIndex = slotIndex,
      proof = Groth16Proof.default,
      host = Address.example,
      collateral = collateral,
    )

    let error = newException(MarketplaceError, "")
    marketplace.setErrorOnGetHost(error)

    let next = !(await state.run(agent))

    check next of SaleErrored
    let errored = SaleErrored(next)
    check errored.error == error
