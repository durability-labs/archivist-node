import pkg/questionable
import pkg/chronos
import pkg/archivist/marketplace/contracts/requests
import pkg/archivist/marketplace/sales/states/errored
import pkg/archivist/marketplace/sales/salesagent
import pkg/archivist/marketplace/sales/salescontext
import pkg/archivist/marketplace/abstractmarketplace

import ../../../../asynctest
import ../../../examples
import ../../../helpers
import ../../../helpers/mockmarketplace
import ../../../helpers/mockclock

asyncchecksuite "sales state 'errored'":
  let request = StorageRequest.example
  let slotIndex = request.ask.slots div 2
  let marketplace = MockMarketplace.new()
  let clock = MockClock.new()

  var state: SaleErrored
  var agent: SalesAgent
  var reprocessSlotWas = false

  setup:
    let onCleanUp = proc(
        reprocessSlot = false, returnedCollateral = Tokens.none
    ) {.async: (raises: []).} =
      reprocessSlotWas = reprocessSlot

    let context = SalesContext(marketplace: marketplace, clock: clock)
    agent = newSalesAgent(context, request.id, slotIndex, request.some)
    agent.onCleanUp = onCleanUp
    state = SaleErrored(error: newException(ValueError, "oh no!"))

  test "calls onCleanUp with reprocessSlot = true":
    state = SaleErrored(error: newException(ValueError, "oh no!"), reprocessSlot: true)
    discard await state.run(agent)
    check eventually reprocessSlotWas == true
