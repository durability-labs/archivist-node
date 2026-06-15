import pkg/questionable
import pkg/chronos
import pkg/archivist/marketplace/contracts/requests
import pkg/archivist/marketplace/sales/states/types
import pkg/archivist/marketplace/sales/states/errored
import pkg/archivist/marketplace/sales/salesagent
import pkg/archivist/marketplace/sales/salescontext
import pkg/archivist/marketplace/sales/statemachine
import pkg/archivist/marketplace/abstractmarketplace

import ../../../../asynctest
import ../../../examples
import ../../../helpers
import ../../../helpers/mockmarketplace
import ../../../helpers/mockclock
import ../../../helpers/mockexponentialbackoff
import ../mockstorage

asyncchecksuite "sales state 'errored'":
  let request = StorageRequest.example
  let slotIndex = request.ask.slots div 2
  let slot = Slot(request: request, slotIndex: slotIndex)
  let clock = MockClock.new()

  var marketplace: MockMarketplace
  var storage: MockStorage
  var state: SaleErrored
  var agent: SalesAgent
  var reprocessSlotWas = false
  var expBackoff: MockExponentialBackoff

  setup:
    let onCleanUp = proc(reprocessSlot = false) {.async: (raises: []).} =
      reprocessSlotWas = reprocessSlot

    marketplace = MockMarketplace.new()
    storage = MockStorage.new()
    expBackoff = MockExponentialBackoff.new()
    let context = SalesContext(marketplace: marketplace, clock: clock, storage: storage)
    var slotInfo = SlotInfo.init(slot.id)
    slotInfo.slot = slot
    agent = newSalesAgent(context, slotInfo, errorBackoff = expBackoff)
    agent.onCleanUp = onCleanUp
    state = SaleErrored(error: newException(ValueError, "oh no!"))

  proc runState(): Future[?State] {.async.} =
    state = SaleErrored(error: newException(ValueError, "oh no!"), reprocessSlot: true)
    return await state.run(agent)

  test "calls exponential backoff delay":
    discard await runState()
    check expBackoff.callCount == 1

  test "transits to unknown state when slot is active":
    let me = await marketplace.getSigner()
    marketplace.activeSlots[me] = @[slot.id]

    let nextState = await runState()
    check !nextState of SaleUnknown

  test "performs cleanup when slot is not active":
    let me = await marketplace.getSigner()
    marketplace.activeSlots[me] = @[]

    let nextState = await runState()
    check isNone nextState
    check eventually reprocessSlotWas == true

  test "deletes slot data when slot is not active":
    let me = await marketplace.getSigner()
    marketplace.activeSlots[me] = @[]

    discard await runState()
    check storage.deleteSlotCalls == @[(request.content.cid, slotIndex)]

  test "transits to error state when slots call fails":
    let nextState = await runState()
    check !nextState of SaleErrored
