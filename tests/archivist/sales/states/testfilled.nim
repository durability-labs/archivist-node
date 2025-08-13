import pkg/questionable/results

import pkg/archivist/clock
import pkg/archivist/contracts/requests
import pkg/archivist/sales
import pkg/archivist/sales/salesagent
import pkg/archivist/sales/salescontext
import pkg/archivist/sales/states/filled
import pkg/archivist/sales/states/errored
import pkg/archivist/sales/states/proving

import ../../../asynctest
import ../../helpers/mockmarket
import ../../examples
import ../../helpers

suite "sales state 'filled'":
  let request = StorageRequest.example
  let slotIndex = request.ask.slots div 2

  var market: MockMarket
  var slot: MockSlot
  var agent: SalesAgent
  var state: SaleFilled
  var onExpiryUpdatePassedExpiry: SecondsSince1970

  setup:
    market = MockMarket.new()
    slot = MockSlot(
      requestId: request.id,
      host: Address.example,
      slotIndex: slotIndex,
      proof: Groth16Proof.default,
    )

    market.requestEnds[request.id] = 321
    onExpiryUpdatePassedExpiry = -1
    let onExpiryUpdate = proc(
        rootCid: Cid, expiry: SecondsSince1970
    ): Future[?!void] {.async: (raises: [CancelledError]).} =
      onExpiryUpdatePassedExpiry = expiry
      return success()
    let context = SalesContext(market: market, onExpiryUpdate: some onExpiryUpdate)

    agent = newSalesAgent(context, request.id, slotIndex, some request)
    state = SaleFilled.new()

  test "switches to proving state when slot is filled by me":
    slot.host = await market.getSigner()
    market.filled = @[slot]
    let next = await state.run(agent)
    check !next of SaleProving

  test "calls onExpiryUpdate with request end":
    slot.host = await market.getSigner()
    market.filled = @[slot]

    let expectedExpiry = 123
    market.requestEnds[request.id] = expectedExpiry
    let next = await state.run(agent)
    check !next of SaleProving
    check onExpiryUpdatePassedExpiry == expectedExpiry

  test "switches to error state when slot is filled by another host":
    slot.host = Address.example
    market.filled = @[slot]
    let next = await state.run(agent)
    check !next of SaleErrored
