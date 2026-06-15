import pkg/archivist/marketplace/contracts/requests
import pkg/archivist/marketplace/sales
import pkg/archivist/marketplace/sales/salesagent
import pkg/archivist/marketplace/sales/salescontext
import pkg/archivist/marketplace/sales/states/filled
import pkg/archivist/marketplace/sales/states/types
import pkg/archivist/marketplace/sales/states/proving

import ../../../../asynctest
import ../../../helpers/mockmarketplace
import ../../../examples
import ../../../helpers
import ../mockstorage

suite "sales state 'filled'":
  let request = StorageRequest.example
  let slotIndex = request.ask.slots div 2
  let slot = Slot(request: request, slotIndex: slotIndex)

  var marketplace: MockMarketplace
  var storage: MockStorage
  var mockSlot: MockSlot
  var agent: SalesAgent
  var state: SaleFilled

  setup:
    marketplace = MockMarketplace.new()
    storage = MockStorage.new()
    mockSlot = MockSlot(
      requestId: request.id,
      host: Address.example,
      slotIndex: slotIndex,
      proof: Groth16Proof.default,
    )
    let context = SalesContext(marketplace: marketplace, storage: storage)
    marketplace.requestEnds[request.id] = 321'StorageTimestamp
    var slotInfo = SlotInfo.init(slot.id)
    slotInfo.slot = slot
    agent = newSalesAgent(context, slotInfo)
    state = SaleFilled.new()

  test "switches to proving state when slot is filled by me":
    mockSlot.host = await marketplace.getSigner()
    marketplace.filled = @[mockSlot]
    let next = await state.run(agent)
    check !next of SaleProving

  test "updates storage expiry with request end":
    mockSlot.host = await marketplace.getSigner()
    marketplace.filled = @[mockSlot]

    let requestEnd = 123'StorageTimestamp
    marketplace.requestEnds[request.id] = requestEnd
    # Expiry includes a buffer of period + proofTimeout past contract end
    let periodicity = marketplace.periodicity()
    let expectedExpiry = requestEnd + periodicity.seconds + marketplace.proofTimeout()
    let next = await state.run(agent)
    check !next of SaleProving
    check storage.updateSlotExpiryCalls.len > 0
    let (cid, index, expiry) = storage.updateSlotExpiryCalls[0]
    check cid == request.content.cid
    check index == mockSlot.slotIndex
    check expiry == expectedExpiry

  test "switches to error state when slot is filled by another host":
    mockSlot.host = Address.example
    marketplace.filled = @[mockSlot]
    let next = await state.run(agent)
    check !next of SaleErrored
