import pkg/chronos

import pkg/archivist/utils/exponentialbackoff

type MockExponentialBackoff* = ref object of ExponentialBackoff
  callCount*: int

func new*(_: type MockExponentialBackoff): MockExponentialBackoff =
  MockExponentialBackoff(callCount: 0)

method applyDelay*(eb: MockExponentialBackoff): Future[void] {.async: (raises: [CancelledError]).} =
  inc eb.callCount
