import pkg/archivist/marketplace/sales
import pkg/archivist/marketplace/sales/salesagent
import pkg/archivist/marketplace/sales/salescontext
import pkg/archivist/marketplace/sales/states/types
import pkg/archivist/marketplace/sales/states/unknown
import pkg/archivist/marketplace/sales/states/filled
import pkg/archivist/marketplace/sales/states/failed
import pkg/archivist/marketplace/sales/states/payout

import ../../../../asynctest
import ../../../helpers/mockmarketplace
import ../../../examples
import ../../../helpers

suite "sales state 'unknown'":
  let request = StorageRequest.example
  let slotIndex = request.ask.slots div 2
  let slot = Slot(request: request, slotIndex: slotIndex)

  var marketplace: MockMarketplace
  var context: SalesContext
  var agent: SalesAgent
  var state: SaleUnknown

  setup:
    marketplace = MockMarketplace.new()
    context = SalesContext(marketplace: marketplace)
    var slotInfo = SlotInfo.init(slot.id)
    slotInfo.slot = slot
    agent = newSalesAgent(context, slotInfo)
    state = SaleUnknown.new()

  test "switches to error state when the slot cannot be retrieved":
    agent = newSalesAgent(context, SlotInfo.init(slot.id))
    let next = await state.run(agent)
    check !next of SaleErrored
    check SaleErrored(!next).error.msg == "slot could not be retrieved"

  test "switches to error state when on chain state cannot be fetched":
    let next = await state.run(agent)
    check !next of SaleErrored

  test "switches to error state when on chain state is 'free'":
    marketplace.slotState[slot.id] = SlotState.Free
    let next = await state.run(agent)
    check !next of SaleErrored
    check SaleErrored(!next).error.msg == "Slot state on chain should not be 'free'"

  test "switches to filled state when on chain state is 'filled'":
    marketplace.slotState[slot.id] = SlotState.Filled
    let next = await state.run(agent)
    check !next of SaleFilled

  test "switches to payout state when on chain state is 'finished'":
    marketplace.slotState[slot.id] = SlotState.Finished
    let next = await state.run(agent)
    check !next of SalePayout

  test "switches to failed state when on chain state is 'failed'":
    marketplace.slotState[slot.id] = SlotState.Failed
    let next = await state.run(agent)
    check !next of SaleFailed
