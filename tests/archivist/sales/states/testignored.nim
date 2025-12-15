import pkg/questionable
import pkg/chronos
import pkg/archivist/marketplace/contracts/requests
import pkg/archivist/marketplace/sales/states/ignored
import pkg/archivist/marketplace/sales/salesagent
import pkg/archivist/marketplace/sales/salescontext
import pkg/archivist/marketplace/abstractmarketplace

import ../../../asynctest
import ../../examples
import ../../helpers
import ../../helpers/mockmarketplace
import ../../helpers/mockclock

asyncchecksuite "sales state 'ignored'":
  let request = StorageRequest.example
  let slotIndex = request.ask.slots div 2
  let marketplace = MockMarketplace.new()
  let clock = MockClock.new()
  let currentCollateral = UInt256.example

  var state: SaleIgnored
  var agent: SalesAgent
  var reprocessSlotWas = false
  var returnedCollateralValue: ?UInt256

  setup:
    let onCleanUp = proc(
        reprocessSlot = false, returnedCollateral = UInt256.none
    ) {.async: (raises: []).} =
      reprocessSlotWas = reprocessSlot
      returnedCollateralValue = returnedCollateral

    let context = SalesContext(marketplace: marketplace, clock: clock)
    agent = newSalesAgent(context, request.id, slotIndex, request.some)
    agent.onCleanUp = onCleanUp
    state = SaleIgnored.new()
    returnedCollateralValue = UInt256.none
    reprocessSlotWas = false

  test "calls onCleanUp with values assigned to SaleIgnored":
    state = SaleIgnored(reprocessSlot: true)
    discard await state.run(agent)
    check eventually reprocessSlotWas == true
    check eventually returnedCollateralValue.isNone

  test "returns collateral when returnsCollateral is true":
    state = SaleIgnored(reprocessSlot: false, returnsCollateral: true)
    discard await state.run(agent)
    check eventually returnedCollateralValue.isSome
