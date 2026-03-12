import pkg/chronos

const
  MaximumBackoff = 60.minutes
  BackoffTimeout = 60.minutes

type ExponentialBackoff* = ref object of RootObj
  lastHit: Moment
  backoffDelay: Duration

method applyDelay*(
    eb: ExponentialBackoff
): Future[void] {.base, async: (raises: [CancelledError]).} =
  if Moment.now() - eb.lastHit > BackoffTimeout:
    # The last hit was too long ago. Reset.
    eb.backoffDelay = 0.seconds

  await sleepAsync(eb.backoffDelay)
  eb.lastHit = Moment.now()

  eb.backoffDelay = (eb.backoffDelay * 2) + 1.seconds
  if eb.backoffDelay > MaximumBackoff:
    eb.backoffDelay = MaximumBackoff
