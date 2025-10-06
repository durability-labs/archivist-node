import pkg/questionable
import pkg/questionable/results
import pkg/chronos
import pkg/chronicles
import pkg/datastore/typedds

import ../utils/asynciter
import ../utils/safeasynciter

{.push raises: [].}

type KeyVal*[T] = tuple[key: Key, value: T]

proc toSafeAsyncIter*[T](queryIter: QueryIter[T]): SafeAsyncIter[QueryResponse[T]] =
  ## Converts `QueryIter[T]` to `SafeAsyncIter[QueryResponse[T]]`

  if queryIter.finished:
    return SafeAsyncIter[QueryResponse[T]].empty()

  proc genNext(): Future[?!QueryResponse[T]] {.async: (raises: [CancelledError]).} =
    await queryIter.next()

  proc isFinished(): bool =
    queryIter.finished

  SafeAsyncIter[QueryResponse[T]].new(genNext, isFinished)

proc filterSuccess*[T](
    iter: AsyncIter[?!QueryResponse[T]]
): Future[AsyncIter[tuple[key: Key, value: T]]] {.async: (raises: [CancelledError]).} =
  ## Filters out any items that are not success

  proc mapping(resOrErr: ?!QueryResponse[T]): Future[?KeyVal[T]] {.async.} =
    without res =? resOrErr, error:
      error "Error occurred when getting QueryResponse", msg = error.msg
      return KeyVal[T].none

    without key =? res.key:
      warn "No key for a QueryResponse"
      return KeyVal[T].none

    without value =? res.value, error:
      error "Error occurred when getting a value from QueryResponse", msg = error.msg
      return KeyVal[T].none

    (key: key, value: value).some

  await mapFilter[?!QueryResponse[T], KeyVal[T]](iter, mapping)

proc filterSuccess*[T](
    iter: SafeAsyncIter[QueryResponse[T]]
): Future[SafeAsyncIter[tuple[key: Key, value: T]]] {.
    async: (raises: [CancelledError])
.} =
  ## Filters out any items that are not success

  proc mapping(
      resOrErr: ?!QueryResponse[T]
  ): Future[Option[?!KeyVal[T]]] {.async: (raises: [CancelledError]).} =
    without res =? resOrErr, error:
      error "Error occurred when getting QueryResponse", msg = error.msg
      return Result[KeyVal[T], ref CatchableError].none

    without key =? res.key:
      warn "No key for a QueryResponse"
      return Result[KeyVal[T], ref CatchableError].none

    without value =? res.value, error:
      error "Error occurred when getting a value from QueryResponse", msg = error.msg
      return Result[KeyVal[T], ref CatchableError].none

    some(success((key: key, value: value)))

  await mapFilter[QueryResponse[T], KeyVal[T]](iter, mapping)
