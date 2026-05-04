import pkg/chronos
import pkg/questionable
import pkg/archivist/marketplace/contracts/requests
import pkg/archivist/marketplace/availability/terms
import pkg/archivist/marketplace/sales/states/preparing
import pkg/archivist/marketplace/sales/states/slotreserving
import pkg/archivist/marketplace/sales/states/cancelled
import pkg/archivist/marketplace/sales/states/failed
import pkg/archivist/marketplace/sales/states/filled
import pkg/archivist/marketplace/sales/states/ignored
import pkg/archivist/marketplace/sales/states/types
import pkg/archivist/marketplace/sales/salesagent
import pkg/archivist/marketplace/sales/salescontext
import pkg/archivist/stores/repostore
import times
import ../../../../asynctest
import ../../../helpers
import ../../../examples
import ../../../helpers/mockmarketplace
import ../../../helpers/mockclock
import ../mockstorage

asyncchecksuite "sales state 'preparing'":
  let request = StorageRequest.example
  let slotIndex = request.ask.slots div 2
  let slot = Slot(request: request, slotIndex: slotIndex)
  var state: SalePreparing
  var agent: SalesAgent
  var marketplace: MockMarketplace
  var storage: MockStorage
  var terms: AvailabilityTerms
  var context: SalesContext

  setup:
    let clock = MockClock.new()
    marketplace = MockMarketplace.new()

    marketplace.requestEnds[request.id] =
      StorageTimestamp.init(clock.now()) + request.ask.duration

    terms = AvailabilityTerms(
      maximumduration: request.ask.duration + 60'u8,
      minimumPricePerBytePerSecond: request.ask.pricePerBytePerSecond,
      maximumCollateralPerByte: request.ask.collateralPerByte,
      availableUntil: none StorageTimestamp,
    )

    storage = MockStorage.new()

    storage.available = request.ask.slotSize

    context = SalesContext(
      marketplace: marketplace,
      clock: clock,
      storage: storage,
      availabilityTerms: some terms,
    )

    var slotInfo = SlotInfo.init(slot.id)
    slotInfo.slot = slot
    agent = newSalesAgent(context, slotInfo)

    state = SalePreparing.new()

  test "switches to cancelled state when request expires":
    let next = state.onCancelled(request)
    check !next of SaleCancelled

  test "switches to failed state when request fails":
    let next = state.onFailed(request)
    check !next of SaleFailed

  test "switches to filled state when slot is filled":
    let next = state.onSlotFilled(request.id, slotIndex)
    check !next of SaleFilled

  test "switches to errored state when the slot cannot be retrieved":
    agent = newSalesAgent(context, SlotInfo.init(slot.id))
    let next = !(await state.run(agent))
    check next of SaleErrored
    check SaleErrored(next).error.msg == "slot could not be retrieved"

  test "switches to ignored state when there is no availability":
    context.availabilityTerms = none AvailabilityTerms
    let next = !(await state.run(agent))
    check next of SaleIgnored
    let ignored = SaleIgnored(next)
    check ignored.reprocessSlot

  test "switches to ignored state when duration is too long":
    terms.maximumDuration = request.ask.duration - 1'StorageDuration
    context.availabilityTerms = some terms
    let next = !(await state.run(agent))
    check next of SaleIgnored

  test "switches to ignored state when reward is too low":
    terms.minimumPricePerBytePerSecond =
      request.ask.pricePerBytePerSecond + 1'TokensPerSecond
    context.availabilityTerms = some terms
    let next = !(await state.run(agent))
    check next of SaleIgnored

  test "switches to ignored state when collateral is too high":
    terms.maximumCollateralPerByte = request.ask.collateralPerByte - 1'Tokens
    context.availabilityTerms = some terms
    let next = !(await state.run(agent))
    check next of SaleIgnored

  test "switches to ignored state when slot is not free":
    marketplace.slotState[slotId(request.id, slotIndex)] = SlotState.Filled
    let next = !(await state.run(agent))
    check next of SaleIgnored

  test "switches to ignored state when request ends after availability ends":
    terms.availableUntil = some marketplace.requestEnds[request.id] - 1
    context.availabilityTerms = some terms
    let next = !(await state.run(agent))
    check next of SaleIgnored

  test "switches to ignored when not enough storage":
    storage.available = request.ask.slotSize - 1
    let next = !(await state.run(agent))
    check next of SaleIgnored
    let ignored = SaleIgnored(next)
    check ignored.reprocessSlot

  test "switches to slot reserving state after reservation created":
    let next = await state.run(agent)
    check !next of SaleSlotReserving
