import pkg/questionable
import pkg/archivist/marketplace/contracts/requests
import pkg/archivist/marketplace/sales/states/filling
import pkg/archivist/marketplace/sales/states/cancelled
import pkg/archivist/marketplace/sales/states/failed
import pkg/archivist/marketplace/sales/states/ignored
import pkg/archivist/marketplace/sales/states/types
import pkg/archivist/marketplace/sales/salesagent
import pkg/archivist/marketplace/sales/salescontext
import ../../../../asynctest
import ../../../examples
import ../../../helpers
import ../../../helpers/mockmarketplace
import ../../../helpers/mockclock

suite "sales state 'filling'":
  let request = StorageRequest.example
  let slotIndex = request.ask.slots div 2
  let slot = Slot(request: request, slotIndex: slotIndex)
  var state: SaleFilling
  var marketplace: MockMarketplace
  var clock: MockClock
  var agent: SalesAgent

  setup:
    clock = MockClock.new()
    marketplace = MockMarketplace.new()
    let context = SalesContext(marketplace: marketplace, clock: clock)
    var slotInfo = SlotInfo.init(slot.id)
    slotInfo.slot = slot
    agent = newSalesAgent(context, slotInfo)
    state = SaleFilling.new()

  test "switches to cancelled state when request expires":
    let next = state.onCancelled(request)
    check !next of SaleCancelled

  test "switches to failed state when request fails":
    let next = state.onFailed(request)
    check !next of SaleFailed

  test "run switches to errored when an error occurs":
    let error = newException(MarketplaceError, "some error")
    marketplace.setErrorOnFillSlot(error)
    marketplace.requested.add(request)
    marketplace.slotState[request.slotId(slotIndex)] = SlotState.Filled

    let next = !(await state.run(agent))
    check next of SaleErrored

    let errored = SaleErrored(next)
    check errored.error == error
