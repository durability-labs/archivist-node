import std/sequtils
import std/sugar
import std/times
import pkg/chronos
import pkg/kvstore
import pkg/taskpools
import pkg/questionable
import pkg/questionable/results
import pkg/archivist/marketplace/sales
import pkg/archivist/marketplace/sales/salesdata
import pkg/archivist/marketplace/sales/salescontext
import pkg/archivist/marketplace/sales/slotqueue
import pkg/archivist/marketplace/availability/store
import pkg/archivist/marketplace/availability/terms
import pkg/archivist/blocktype as bt
import pkg/archivist/node
import pkg/archivist/utils/asyncstatemachine
import ../../../asynctest
import ../../helpers
import ../../helpers/mockmarketplace
import ../../helpers/mockclock
import ../../helpers/always
import ../../examples
import ./helpers/periods
import ./mockstorage

asyncchecksuite "Sales - start":
  let proof = Groth16Proof.example

  var request: StorageRequest
  var sales: Sales
  var marketplace: MockMarketplace
  var storage: MockStorage
  var clock: MockClock
  var queue: SlotQueue
  var itemsProcessed: seq[SlotQueueItem]
  var metaTp: Taskpool
  var metaDs: KVStore

  setup:
    request = StorageRequest(
      ask: StorageAsk(
        slots: 4,
        slotSize: 100.uint64,
        duration: 60'StorageDuration,
        pricePerBytePerSecond: 1'TokensPerSecond,
        collateralPerByte: 1'Tokens,
      ),
      content: StorageContent(
        cid: Cid.init("zb2rhheVmk3bLks5MgzTqyznLu1zqGH5jrfTA1eAZXrjx7Vob").tryGet
      ),
      expiry: 60'StorageDuration,
    )

    marketplace = MockMarketplace.new()
    clock = MockClock.new()
    metaTp = Taskpool.new(num_threads = 4)
    metaDs = SQLiteKVStore.new(SqliteMemory, metaTp).tryGet()
    let availability = AvailabilityStore.new(metaDs)
    storage = MockStorage.new()
    sales = Sales.new(marketplace, clock, availability, storage)
    queue = sales.context.slotQueue
    itemsProcessed = @[]

  teardown:
    await sales.stop()
    (await metaDs.close()).tryGet()
    metaTp.shutdown()

  proc fillSlot(slotIdx: uint64 = 0.uint64) {.async.} =
    let address = await marketplace.getSigner()
    let slot =
      MockSlot(requestId: request.id, slotIndex: slotIdx, proof: proof, host: address)
    marketplace.filled.add slot
    marketplace.slotState[slotId(request.id, slotIdx)] = SlotState.Filled

  test "load slots when Sales module starts":
    let me = await marketplace.getSigner()

    request.ask.slots = 2
    marketplace.requested = @[request]
    marketplace.requestState[request.id] = RequestState.New

    let slot0 = MockSlot(requestId: request.id, slotIndex: 0, proof: proof, host: me)
    await fillSlot(slot0.slotIndex)

    let slot1 = MockSlot(requestId: request.id, slotIndex: 1, proof: proof, host: me)
    await fillSlot(slot1.slotIndex)

    marketplace.activeSlots[me] = @[request.slotId(0), request.slotId(1)]
    marketplace.requested = @[request]
    marketplace.activeRequests[me] = @[request.id]

    !await sales.start()

    check eventually sales.agents.len == 2
    check sales.agents.any(agent => agent.data.slotInfo.slotId == slotId(request.id, 0))
    check sales.agents.any(agent => agent.data.slotInfo.slotId == slotId(request.id, 1))

asyncchecksuite "Sales":
  let proof = Groth16Proof.example

  var minPricePerBytePerSecond: TokensPerSecond
  var request: StorageRequest
  var sales: Sales
  var marketplace: MockMarketplace
  var clock: MockClock
  var storage: MockStorage
  var queue: SlotQueue
  var itemsProcessed: seq[SlotQueueItem]
  var metaTp: Taskpool
  var metaDs: KVStore

  setup:
    minPricePerBytePerSecond = 1'TokensPerSecond
    request = StorageRequest(
      ask: StorageAsk(
        slots: 4,
        slotSize: 100.uint64,
        duration: 60'StorageDuration,
        pricePerBytePerSecond: minPricePerBytePerSecond,
        collateralPerByte: 1'Tokens,
      ),
      content: StorageContent(
        cid: Cid.init("zb2rhheVmk3bLks5MgzTqyznLu1zqGH5jrfTA1eAZXrjx7Vob").tryGet
      ),
      expiry: 60'StorageDuration,
    )

    marketplace = MockMarketplace.new()
    storage = MockStorage.new()

    let me = await marketplace.getSigner()
    marketplace.activeSlots[me] = @[]

    clock = MockClock.new()
    metaTp = Taskpool.new(num_threads = 4)
    metaDs = SQLiteKVStore.new(SqliteMemory, metaTp).tryGet()
    let availability = AvailabilityStore.new(metaDs)
    sales = Sales.new(marketplace, clock, availability, storage)
    queue = sales.context.slotQueue
    itemsProcessed = @[]
    !await sales.start()

  teardown:
    await sales.stop()
    (await metaDs.close()).tryGet()
    metaTp.shutdown()

  proc isInState(idx: int, state: string): bool =
    proc description(state: State): string =
      $state

    if idx >= sales.agents.len:
      return false
    sales.agents[idx].query(description) == state.some

  proc allowRequestToStart() {.async.} =
    check eventually isInState(0, "SaleInitialProving")
    # it won't start proving until the next period
    await clock.advanceToNextPeriod(marketplace)

  proc setAvailability(
      availableStorage = 100'u64,
      minimumPricePerBytePerSecond = 1'TokensPerSecond,
      maximumCollateralPerByte = 1'Tokens,
      maximumDuration = 60'StorageDuration,
      availableUntil = none StorageTimestamp,
  ) {.async.} =
    storage.available = availableStorage
    let terms = AvailabilityTerms(
      minimumPricePerBytePerSecond: minimumPricePerBytePerSecond,
      maximumCollateralPerByte: maximumCollateralPerByte,
      maximumDuration: maximumDuration,
      availableUntil: availableUntil,
    )
    !await sales.updateAvailability(terms)

  proc notProcessed(itemsProcessed: seq[SlotQueueItem], request: StorageRequest): bool =
    let items = SlotQueueItem.init(request)
    for i in 0 ..< items.len:
      if itemsProcessed.contains(items[i]):
        return false
    return true

  proc addRequestToSaturatedQueue(): Future[StorageRequest] {.async.} =
    queue.onProcessSlot = proc(
        item: SlotQueueItem
    ) {.async: (raises: [CancelledError]).} =
      try:
        await sleepAsync(10.millis)
        itemsProcessed.add item
      except CancelledError as exc:
        checkpoint(exc.msg)

    var request1 = StorageRequest.example
    request1.ask.collateralPerByte = request.ask.collateralPerByte + 1
    await setAvailability()
    # saturate queue
    while queue.len < queue.size - 1:
      await marketplace.requestStorage(StorageRequest.example)
    # send request
    await marketplace.requestStorage(request1)
    await sleepAsync(5.millis) # wait for request slots to be added to queue
    return request1

  test "processes all request's slots once StorageRequested emitted":
    queue.onProcessSlot = proc(
        item: SlotQueueItem
    ) {.async: (raises: [CancelledError]).} =
      itemsProcessed.add item
    await setAvailability()
    await marketplace.requestStorage(request)
    let items = SlotQueueItem.init(request)
    check eventually items.allIt(itemsProcessed.contains(it))

  test "removes request from slot queue once RequestFailed emitted":
    let request1 = await addRequestToSaturatedQueue()
    marketplace.emitRequestFailed(request1.id)
    check always itemsProcessed.notProcessed(request1)

  test "removes request from slot queue once RequestFulfilled emitted":
    let request1 = await addRequestToSaturatedQueue()
    marketplace.emitRequestFulfilled(request1.id)
    check always itemsProcessed.notProcessed(request1)

  test "removes slot index from slot queue once SlotFilled emitted":
    let request1 = await addRequestToSaturatedQueue()
    marketplace.emitSlotFilled(request1.id, 1.uint64)
    let expected = SlotQueueItem.init(request1, 1'u16)
    check always (not itemsProcessed.contains(expected))

  test "removes slot index from slot queue once SlotReservationsFull emitted":
    let request1 = await addRequestToSaturatedQueue()
    marketplace.emitSlotReservationsFull(request1.id, 1.uint64)
    let expected = SlotQueueItem.init(request1, 1'u16)
    check always (not itemsProcessed.contains(expected))

  test "adds slot index to slot queue once SlotFreed emitted":
    queue.onProcessSlot = proc(
        item: SlotQueueItem
    ) {.async: (raises: [CancelledError]).} =
      itemsProcessed.add item

    await setAvailability()
    marketplace.requested.add request # "contract" must be able to return request

    marketplace.emitSlotFreed(request.id, 2.uint64)

    let expected = SlotQueueItem.init(request, 2.uint16)

    check eventually itemsProcessed.contains(expected)

  test "items in queue are readded once ignored":
    await marketplace.requestStorage(request)
    let items = SlotQueueItem.init(request)
    check eventually queue.len > 0
      # queue starts paused, allow items to be added to the queue
    check eventually queue.paused
    # The first processed item will be will have been re-pushed. Then, once this
    # item is processed by the queue, the queue will be paused. This test could
    # check item existence in the queue, but that would require inspecting
    # onProcessSlot to see which item was first, and overridding onProcessSlot
    # will prevent the queue working as expected in the Sales module.
    check eventually queue.len == 4

    for item in items:
      check queue.contains(item)

  test "retrieves and stores data locally":
    await setAvailability()
    await marketplace.requestStorage(request)
    check eventually storage.storeSlotCalls.len > 0
    for (cid, slotIndex, slotSize, _, _) in storage.storeSlotCalls:
      check cid == request.content.cid
      check slotIndex < request.ask.slots
      check slotSize == request.ask.slotSize

  test "generates proof of storage":
    await setAvailability()
    await marketplace.requestStorage(request)
    await allowRequestToStart()
    check eventually storage.proveSlotCalls.len > 0
    for (cid, index, _) in storage.proveSlotCalls:
      check cid == request.content.cid
      check index < request.ask.slots

  test "fills a slot":
    storage.proveSlotResult = success(proof)
    await setAvailability()
    await marketplace.requestStorage(request)
    await allowRequestToStart()

    check eventually marketplace.filled.len > 0
    check marketplace.filled[0].requestId == request.id
    check marketplace.filled[0].slotIndex < request.ask.slots
    check marketplace.filled[0].proof == proof
    check marketplace.filled[0].host == await marketplace.getSigner()
