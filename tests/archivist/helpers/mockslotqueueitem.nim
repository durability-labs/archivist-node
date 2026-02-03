import pkg/archivist/marketplace/contracts/requests
import pkg/archivist/marketplace/sales/slotqueue

type MockSlotQueueItem* = object
  requestId*: RequestId
  slotIndex*: uint16
  slotSize*: uint64
  duration*: StorageDuration
  pricePerBytePerSecond*: TokensPerSecond
  collateral*: Tokens
  expiry*: StorageTimestamp
  availabilitiesVersion*: uint64

proc toSlotQueueItem*(item: MockSlotQueueItem): SlotQueueItem =
  SlotQueueItem.init(
    requestId = item.requestId,
    slotIndex = item.slotIndex,
    ask = StorageAsk(
      slotSize: item.slotSize,
      duration: item.duration,
      pricePerBytePerSecond: item.pricePerBytePerSecond,
    ),
    expiry = item.expiry,
    availabilitiesVersion = item.availabilitiesVersion,
    collateral = item.collateral,
  )
