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
  let clock = MockClock.new()

  let currentCollateral = Tokens.example

  var marketplace: MockMarketplace
  var state: SaleCancelled
  var agent: SalesAgent
  var reprocessSlotWas: ?bool
  var returnedCollateralValue: ?Tokens

  setup:
    marketplace = MockMarketplace.new()
    let onCleanUp = proc(
        reprocessSlot = false, returnedCollateral = Tokens.none
    ) {.async: (raises: []).} =
      reprocessSlotWas = some reprocessSlot
      returnedCollateralValue = returnedCollateral

    let context = SalesContext(marketplace: marketplace, clock: clock)
    agent = newSalesAgent(context, request.id, slotIndex, request.some)
    agent.onCleanUp = onCleanUp
    state = SaleCancelled.new()
    reprocessSlotWas = bool.none
    returnedCollateralValue = Tokens.none
  teardown:
    reprocessSlotWas = bool.none
    returnedCollateralValue = Tokens.none

  test "calls onCleanUp with reprocessSlot = true, and returnedCollateral = currentCollateral":
    marketplace.fillSlot(
      requestId = request.id,
      slotIndex = slotIndex,
      proof = Groth16Proof.default,
      host = await marketplace.getSigner(),
      collateral = currentCollateral,
    )
    discard await state.run(agent)
    check eventually reprocessSlotWas == some false
    check eventually returnedCollateralValue == some currentCollateral

  test "completes the cancelled state when free slot error is raised and the collateral is returned when a host is hosting a slot":
    marketplace.fillSlot(
      requestId = request.id,
      slotIndex = slotIndex,
      proof = Groth16Proof.default,
      host = await marketplace.getSigner(),
      collateral = currentCollateral,
    )

    let error =
      newException(SlotStateMismatchError, "Failed to free slot, slot is already free")
    marketplace.setErrorOnFreeSlot(error)

    let next = await state.run(agent)
    check next == none State
    check eventually reprocessSlotWas == some false
    check eventually returnedCollateralValue == some currentCollateral

  test "completes the cancelled state when free slot error is raised and the collateral is not returned when a host is not hosting a slot":
    discard marketplace.reserveSlot(requestId = request.id, slotIndex = slotIndex)
    marketplace.fillSlot(
      requestId = request.id,
      slotIndex = slotIndex,
      proof = Groth16Proof.default,
      host = Address.example,
      collateral = currentCollateral,
    )

    let error =
      newException(SlotStateMismatchError, "Failed to free slot, slot is already free")
    marketplace.setErrorOnFreeSlot(error)

    let next = await state.run(agent)
    check next == none State
    check eventually reprocessSlotWas == some false
    check eventually returnedCollateralValue == Tokens.none

  test "calls onCleanUp and returns the collateral when an error is raised":
    marketplace.fillSlot(
      requestId = request.id,
      slotIndex = slotIndex,
      proof = Groth16Proof.default,
      host = Address.example,
      collateral = currentCollateral,
    )

    let error = newException(MarketplaceError, "")
    marketplace.setErrorOnGetHost(error)

    let next = !(await state.run(agent))

    check next of SaleErrored
    let errored = SaleErrored(next)
    check errored.error == error
