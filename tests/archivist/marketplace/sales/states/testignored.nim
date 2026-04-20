import pkg/chronos
import pkg/archivist/marketplace/contracts/requests
import pkg/archivist/marketplace/sales/states/ignored
import pkg/archivist/marketplace/sales/salesagent
import pkg/archivist/marketplace/sales/salescontext
import pkg/archivist/marketplace/abstractmarketplace

import ../../../../asynctest
import ../../../examples
import ../../../helpers
import ../../../helpers/mockmarketplace
import ../../../helpers/mockclock

asyncchecksuite "sales state 'ignored'":
  let request = StorageRequest.example
  let slotIndex = request.ask.slots div 2
  let slot = Slot(request: request, slotIndex: slotIndex)
  let marketplace = MockMarketplace.new()
  let clock = MockClock.new()

  var state: SaleIgnored
  var agent: SalesAgent
  var reprocessSlotWas = false

  setup:
    let onCleanUp = proc(reprocessSlot = false) {.async: (raises: []).} =
      reprocessSlotWas = reprocessSlot

    let context = SalesContext(marketplace: marketplace, clock: clock)
    agent = newSalesAgent(context, SlotInfo.init(slot.id))
    agent.onCleanUp = onCleanUp
    state = SaleIgnored.new()
    reprocessSlotWas = false

  test "calls onCleanUp with values assigned to SaleIgnored":
    state = SaleIgnored(reprocessSlot: true)
    discard await state.run(agent)
    check eventually reprocessSlotWas == true
