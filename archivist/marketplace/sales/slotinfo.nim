import pkg/questionable
import ../contracts/requests

type SlotInfo* = object
  ## Allows for incremental gathering of information about a `Slot`.
  ## You can start out with as little as a `SlotId`, and gradually add
  ## information as it's read from the chain, eventually ending up with a full
  ## `Slot`.
  ## The goal is to minimize reads from the chain, while allowing sales
  ## decisions to be made with the information that is already present. For
  ## instance, when a request is posted on-chain, the request id, slot index and
  ## storage ask are immediately available. Deciding whether or not the slot is
  ## worth picking up can already be done based on this information alone.
  slotId: SlotId
  requestId: ?RequestId
  slotIndex: ?uint64
  ask: ?StorageAsk
  request: ?StorageRequest
  slot: ?Slot

func init*(_: type SlotInfo, slotId: SlotId): SlotInfo =
  ## Initialize `SlotInfo` with only a slot id.
  SlotInfo(slotId: slotId)

func init*(_: type SlotInfo, requestId: RequestId, slotIndex: uint64): SlotInfo =
  ## Initialize `SlotInfo` with a request id and a slot index. This also
  ## determines the slot id.
  let slotId = slotId(requestId, slotIndex)
  SlotInfo(slotId: slotId, requestId: some requestId, slotIndex: some slotIndex)

func `ask=`*(info: var SlotInfo, ask: StorageAsk) =
  ## Adds information about duration and costs.
  info.ask = some ask

func `request=`*(info: var SlotInfo, request: StorageRequest) =
  ## Adds information about the request, this also determines `requestId`
  ## and `ask`. If the slot index was previously set, then the entire `Slot`
  ## becomes available.
  info.request = some request
  info.ask = some request.ask
  info.requestId = some request.id
  if slotIndex =? info.slotIndex:
    let slot = Slot(request: request, slotIndex: slotIndex)
    info.slot = some slot
    info.slotId = slot.id

func `slot=`*(info: var SlotInfo, slot: Slot) =
  ## Sets all information about a slot.
  info.slot = some slot
  info.request = some slot.request
  info.ask = some slot.request.ask
  info.slotIndex = some slot.slotIndex
  info.requestId = some slot.request.id
  info.slotId = slot.id

func slotId*(info: SlotInfo): SlotId =
  info.slotId

func requestId*(info: SlotInfo): ?RequestId =
  info.requestId

func slotIndex*(info: SlotInfo): ?uint64 =
  info.slotIndex

func ask*(info: SlotInfo): ?StorageAsk =
  info.ask

func request*(info: SlotInfo): ?StorageRequest =
  info.request

func slot*(info: SlotInfo): ?Slot =
  info.slot
