import pkg/archivist/marketplace/contracts/requests
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
  let slotId = slotId(request.id, slotIndex)

  var marketplace: MockMarketplace
  var context: SalesContext
  var agent: SalesAgent
  var state: SaleUnknown

  setup:
    marketplace = MockMarketplace.new()
    context = SalesContext(marketplace: marketplace)
    agent = newSalesAgent(context, request.id, slotIndex, request.some)
    state = SaleUnknown.new()

  test "switches to error state when the request cannot be retrieved":
    agent = newSalesAgent(context, request.id, slotIndex, StorageRequest.none)
    let next = await state.run(agent)
    check !next of SaleErrored
    check SaleErrored(!next).error.msg == "request could not be retrieved"

  test "switches to error state when on chain state cannot be fetched":
    let next = await state.run(agent)
    check !next of SaleErrored

  test "switches to error state when on chain state is 'free'":
    marketplace.slotState[slotId] = SlotState.Free
    let next = await state.run(agent)
    check !next of SaleErrored
    check SaleErrored(!next).error.msg == "Slot state on chain should not be 'free'"

  test "switches to filled state when on chain state is 'filled'":
    marketplace.slotState[slotId] = SlotState.Filled
    let next = await state.run(agent)
    check !next of SaleFilled

  test "switches to payout state when on chain state is 'finished'":
    marketplace.slotState[slotId] = SlotState.Finished
    let next = await state.run(agent)
    check !next of SalePayout

  test "switches to failed state when on chain state is 'failed'":
    marketplace.slotState[slotId] = SlotState.Failed
    let next = await state.run(agent)
    check !next of SaleFailed
