import pkg/questionable
import pkg/chronos
import pkg/archivist/contracts/requests
import pkg/archivist/sales/states/payout
import pkg/archivist/sales/states/finished
import pkg/archivist/sales/salesagent
import pkg/archivist/sales/salescontext
import pkg/archivist/market

import ../../../asynctest
import ../../examples
import ../../helpers
import ../../helpers/mockmarket
import ../../helpers/mockclock

asyncchecksuite "sales state 'payout'":
  let request = StorageRequest.example
  let slotIndex = request.ask.slots div 2
  let clock = MockClock.new()

  let currentCollateral = UInt256.example

  var market: MockMarket
  var state: SalePayout
  var agent: SalesAgent

  setup:
    market = MockMarket.new()

    let context = SalesContext(market: market, clock: clock)
    agent = newSalesAgent(context, request.id, slotIndex, request.some)
    state = SalePayout.new()

  test "switches to 'finished' state and provides returnedCollateral":
    market.fillSlot(
      requestId = request.id,
      slotIndex = slotIndex,
      proof = Groth16Proof.default,
      host = Address.example,
      collateral = currentCollateral,
    )
    let next = await state.run(agent)
    check !next of SaleFinished
    check SaleFinished(!next).returnedCollateral == some currentCollateral
