import pkg/questionable
import pkg/questionable/results
import pkg/chronos
import pkg/chronicles
import pkg/kvstore
import pkg/iter

{.push raises: [].}

type KeyVal*[T] = tuple[key: Key, value: T]

proc toAsyncIter*[T](queryIter: QueryIter[T]): AsyncIter[?!(?KVRecord[T])] =
  ## Converts kvstore `QueryIter[T]` to an `AsyncIter` of query results.
  ##
  AsyncIter[?!(?KVRecord[T])].new(
    proc(): Future[?!(?KVRecord[T])] {.async.} =
      await queryIter.next()
    ,
    proc(): bool =
      queryIter.finished,
    proc(): Future[void] {.async.} =
      if err =? (await dispose(queryIter)).errorOption:
        raise toIteratorError(err)
    ,
    proc(): bool =
      queryIter.disposed,
  )

proc filterSuccess*[T](
    iter: AsyncIter[?!(?KVRecord[T])]
): Future[AsyncIter[KeyVal[T]]] {.async: (raises: [CancelledError]).} =
  ## Filters out any items that are not success

  let mapping = proc(resOrErr: ?!(?KVRecord[T])): Future[?KeyVal[T]] {.async.} =
    without recordOpt =? resOrErr, error:
      error "Error occurred when getting KVRecord", msg = error.msg
      return KeyVal[T].none

    without record =? recordOpt:
      return KeyVal[T].none

    (key: record.key, value: record.val).some

  await mapFilter[?!RecordOption[T], KeyVal[T]](iter, mapping)
