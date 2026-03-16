import pkg/questionable
import pkg/questionable/results
import pkg/chronos
import pkg/chronicles
import pkg/kvstore

import ../utils/asynciter
import ../utils/safeasynciter

{.push raises: [].}

type KeyVal*[T] = tuple[key: Key, value: T]

proc toSafeAsyncIter*[T](queryIter: QueryIter[T]): SafeAsyncIter[?KVRecord[T]] =
  ## Converts kvstore `QueryIter[T]` to `SafeAsyncIter[?KVRecord[T]]`
  ##
  proc genNext(): Future[?!(?KVRecord[T])] {.async: (raises: [CancelledError]).} =
    await queryIter.next()

  proc isFinished(): bool =
    queryIter.finished

  proc onDispose(): Future[?!void] {.async: (raises: []).} =
    # kvquery.dispose returns Future[?!void] - await and propagate errors
    return await dispose(queryIter)

  proc isDisposed(): bool =
    queryIter.disposed

  # Always create the wrapper - even if queryIter.finished, we still need
  # to dispose the underlying iterator to release its resources
  SafeAsyncIter[?KVRecord[T]].new(
    genNext = genNext,
    isFinished = isFinished,
    dispose = onDispose,
    isDisposed = isDisposed,
  )

proc filterSuccess*[T](
    iter: AsyncIter[?!(?KVRecord[T])]
): Future[AsyncIter[KeyVal[T]]] {.async: (raises: [CancelledError]).} =
  ## Filters out any items that are not success

  proc mapping(resOrErr: ?!(?KVRecord[T])): Future[?KeyVal[T]] {.async.} =
    without recordOpt =? resOrErr, error:
      error "Error occurred when getting KVRecord", msg = error.msg
      return KeyVal[T].none

    without record =? recordOpt:
      return KeyVal[T].none

    (key: record.key, value: record.val).some

  await mapFilter[?!RecordOption[T], KeyVal[T]](iter, mapping)

proc filterSuccess*[T](
    iter: SafeAsyncIter[(?KVRecord[T])]
): Future[SafeAsyncIter[KeyVal[T]]] {.async: (raises: [CancelledError]).} =
  ## Filters out any items that are not success

  proc mapping(
      resOrErr: ?!(?KVRecord[T])
  ): Future[Option[?!KeyVal[T]]] {.async: (raises: [CancelledError]).} =
    without recordOpt =? resOrErr, error:
      error "Error occurred when getting KVRecord", msg = error.msg
      return Result[KeyVal[T], ref CatchableError].none

    without record =? recordOpt:
      return Result[KeyVal[T], ref CatchableError].none

    some(success((key: record.key, value: record.val)))

  await mapFilter[?KVRecord[T], KeyVal[T]](iter, mapping)
