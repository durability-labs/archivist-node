import pkg/chronos

import pkg/archivist/utils/exponentialbackoff

type MockExponentialBackoff* = ref object of ExponentialBackoff
  callCount*: int

func new*(_: type MockExponentialBackoff): MockExponentialBackoff =
  MockExponentialBackoff(callCount: 0)

method applyDelay*(eb: MockExponentialBackoff) {.async: (raises: [CancelledError]).} =
  inc eb.callCount
  await sleepAsync(1.millis)
