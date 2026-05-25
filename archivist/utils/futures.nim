import pkg/chronos

template internalWrap(future: untyped): untyped =
  ## Wrap ``future`` in an outter future that will proxy ``future`` and
  ## ``retFuture``, except for cancellations initiated on ``retFuture``.
  ## Cancellations inititated from ``future``, will be propagated to
  ## ``retFuture``.
  ##
  ## This is similar to chronos.join(), except that it allows for value
  ## carring futures, and propagates cancellations from the wrapped to
  ## the wrapper.
  ##

  let retFuture = (type future).init("archivist.wrap()")
  proc continuation(udata: pointer) {.gcsafe, raises: [].} =
    if not retFuture.finished:
      if future.finished:
        if not future.failed:
          when T isnot void:
            try:
              if future.cancelled and not retFuture.cancelled:
                retFuture.cancel()
              else:
                retFuture.complete(future.read)
            except CatchableError as exc:
              raiseAssert(exc.msg)
          else:
            retFuture.complete()
        else:
          retFuture.fail(future.error, warn = false)

  proc cancellation(udata: pointer) {.gcsafe.} =
    future.removeCallback(continuation)
    retFuture.cancelCallback = nil

  if not (future.finished()):
    future.addCallback(continuation)
    retFuture.cancelCallback = cancellation
  else:
    continuation(nil)

  retFuture

proc wrap*[T](future: Future[T]): Future[T] =
  ## Wrap ``future`` in an outter future that will proxy ``future`` and
  ## ``retFuture``, except for cancellations initiated on ``retFuture``.
  ## Cancellations inititated from ``future``, will be propagated to
  ## ``retFuture``.
  ##
  ## This is similar to chronos.join(), except that it allows for value
  ## carring futures, and propagates cancellations from the wrapped to
  ## the wrapper.
  ##

  internalWrap(future)

proc wrap*[T, E](future: InternalRaisesFuture[T, E]): InternalRaisesFuture[T, E] =
  ## Wrap ``future`` in an outter future that will proxy ``future`` and
  ## ``retFuture``, except for cancellations initiated on ``retFuture``.
  ## Cancellations inititated from ``future``, will be propagated to
  ## ``retFuture``.
  ##
  ## This is similar to chronos.join(), except that it allows for value
  ## carring futures, and propagates cancellations from the wrapped to
  ## the wrapper.
  ##

  internalWrap(future)
