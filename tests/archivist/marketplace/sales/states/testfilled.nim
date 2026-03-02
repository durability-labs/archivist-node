import pkg/questionable/results

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

  var marketplace: MockMarketplace
  var storage: MockStorage
  var slot: MockSlot
  var agent: SalesAgent
  var state: SaleFilled

  setup:
    marketplace = MockMarketplace.new()
    storage = MockStorage.new()
    slot = MockSlot(
      requestId: request.id,
      host: Address.example,
      slotIndex: slotIndex,
      proof: Groth16Proof.default,
    )
    let context = SalesContext(marketplace: marketplace, storage: storage)

    marketplace.requestEnds[request.id] = 321'StorageTimestamp
    agent = newSalesAgent(context, request.id, slotIndex, some request)
    state = SaleFilled.new()

  test "switches to proving state when slot is filled by me":
    slot.host = await marketplace.getSigner()
    marketplace.filled = @[slot]
    let next = await state.run(agent)
    check !next of SaleProving

  test "updates storage expiry with request end":
    slot.host = await marketplace.getSigner()
    marketplace.filled = @[slot]

    let expectedExpiry = 123'StorageTimestamp
    marketplace.requestEnds[request.id] = expectedExpiry
    let next = await state.run(agent)
    check !next of SaleProving
    check storage.updateSlotExpiryCalls.len > 0
    let (cid, index, expiry) = storage.updateSlotExpiryCalls[0]
    check cid == request.content.cid
    check index == slot.slotIndex
    check expiry == expectedExpiry

  test "switches to error state when slot is filled by another host":
    slot.host = Address.example
    marketplace.filled = @[slot]
    let next = await state.run(agent)
    check !next of SaleErrored
