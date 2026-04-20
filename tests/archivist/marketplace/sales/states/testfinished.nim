import pkg/questionable
import pkg/archivist/marketplace/contracts/requests
import pkg/archivist/marketplace/sales/states/finished
import pkg/archivist/marketplace/sales/states/cancelled
import pkg/archivist/marketplace/sales/states/failed
import pkg/archivist/marketplace/sales/salesagent
import pkg/archivist/marketplace/sales/salescontext
import pkg/archivist/marketplace/abstractmarketplace

import ../../../../asynctest
import ../../../examples
import ../../../helpers
import ../../../helpers/mockmarketplace
import ../../../helpers/mockclock

asyncchecksuite "sales state 'finished'":
  let request = StorageRequest.example
  let slotIndex = request.ask.slots div 2
  let slot = Slot(request: request, slotIndex: slotIndex)
  let clock = MockClock.new()

  let currentCollateral = Tokens.example

  var marketplace: MockMarketplace
  var state: SaleFinished
  var agent: SalesAgent
  var reprocessSlotWas = bool.none
  var returnedCollateralValue = Tokens.none
  var saleCleared = bool.none

  setup:
    marketplace = MockMarketplace.new()
    let onCleanUp = proc(
        reprocessSlot = false, returnedCollateral = Tokens.none
    ) {.async: (raises: []).} =
      reprocessSlotWas = some reprocessSlot
      returnedCollateralValue = returnedCollateral

    let context = SalesContext(marketplace: marketplace, clock: clock)
    agent = newSalesAgent(context, SlotInfo.init(slot.id))
    agent.onCleanUp = onCleanUp
    state = SaleFinished(returnedCollateral: some currentCollateral)

  test "switches to cancelled state when request expires":
    let next = state.onCancelled(request)
    check !next of SaleCancelled

  test "switches to failed state when request fails":
    let next = state.onFailed(request)
    check !next of SaleFailed

  test "calls onCleanUp with reprocessSlot = true, and returnedCollateral = currentCollateral":
    discard await state.run(agent)
    check eventually reprocessSlotWas == some false
    check eventually returnedCollateralValue == some currentCollateral
