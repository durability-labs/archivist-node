import pkg/chronos
import pkg/questionable
import ../../utils/exponentialbackoff
import ./slotinfo
import ./slotqueue

type SalesData* = ref object
  slotInfo*: SlotInfo
  slotQueueItem*: ?SlotQueueItem
  cancelled*: Future[void]
  errorBackoff*: ExponentialBackoff
