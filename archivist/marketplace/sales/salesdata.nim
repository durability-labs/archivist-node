import pkg/chronos
import pkg/questionable
import ../contracts/requests
import ./slotqueue
import ../../utils/exponentialbackoff

type SalesData* = ref object
  requestId*: RequestId
  request*: ?StorageRequest
  slotIndex*: uint64
  cancelled*: Future[void]
  slotQueueItem*: ?SlotQueueItem
  errorBackoff*: ExponentialBackoff
