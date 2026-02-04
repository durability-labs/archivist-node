## AsyncIter[T] - Asynchronous iterator with mandatory disposal
##
## Similar to `Iter[Future[T]]` with addition of methods specific to asynchronous processing.
##
## USAGE CONTRACT:
## 1. Single-consumer: Do NOT call next() concurrently from multiple tasks
## 2. Disposal required: Always call dispose() when done (use defer or try/finally)
## 3. No concurrent dispose: Do NOT call dispose() concurrently or while next() is in-flight
## 4. After dispose: Calling next() will raise an error
##
## Example:
##   let iter = createIterator()
##   defer: await iter.dispose()
##   while not iter.finished:
##     let item = await iter.next()
##     # process item

import std/sugar

import pkg/questionable
import pkg/questionable/results
import pkg/chronos

import ./iter

export iter

type
  AsyncDispose* = proc(): Future[void] {.async, gcsafe, closure.}
  AsyncIsDisposed* = proc(): bool {.raises: [], gcsafe, closure.}

  AsyncIter*[T] = ref object
    finished: bool
    next*: GenNext[Future[T]]
    disposeImpl: AsyncDispose
    disposedImpl: AsyncIsDisposed

proc finish*[T](self: AsyncIter[T]): void =
  self.finished = true

proc finished*[T](self: AsyncIter[T]): bool =
  self.finished

proc disposed*[T](self: AsyncIter[T]): bool =
  self.disposedImpl()

proc dispose*[T](self: AsyncIter[T]): Future[void] {.async.} =
  ## Dispose the iterator and release any underlying resources.
  ## Caller is responsible for calling this when done with the iterator.
  ## Idempotent - safe to call multiple times.
  ## Sets finished = true to prevent further iteration.
  ## Uses noCancel to ensure cleanup completes even if caller is cancelled.
  if not self.disposed:
    self.finished = true
    await noCancel self.disposeImpl()

iterator items*[T](self: AsyncIter[T]): Future[T] =
  while not self.finished:
    yield self.next()

iterator pairs*[T](self: AsyncIter[T]): tuple[key: int, val: Future[T]] {.inline.} =
  var i = 0
  while not self.finished:
    yield (i, self.next())
    inc(i)

proc map*[T, U](fut: Future[T], fn: Function[T, U]): Future[U] {.async.} =
  let t = await fut
  fn(t)

proc flatMap*[T, U](fut: Future[T], fn: Function[T, Future[U]]): Future[U] {.async.} =
  let t = await fut
  await fn(t)

proc new*[T](
    _: type AsyncIter[T],
    genNext: GenNext[Future[T]],
    isFinished: IsFinished,
    dispose: AsyncDispose,
    isDisposed: AsyncIsDisposed,
    finishOnErr: bool = true,
): AsyncIter[T] =
  ## Creates a new Iter using elements returned by supplier function `genNext`.
  ## Iter is finished whenever `isFinished` returns true.
  ## Caller is responsible for calling `dispose()` when done with the iterator.
  ##
  ## IMPORTANT: dispose and isDisposed callbacks are REQUIRED - passing nil will assert.

  doAssert dispose != nil, "dispose callback is required"
  doAssert isDisposed != nil, "isDisposed callback is required"

  var iter = AsyncIter[T](disposeImpl: dispose, disposedImpl: isDisposed)

  proc next(): Future[T] {.async.} =
    if iter.disposed:
      raise newException(CatchableError, "AsyncIter is disposed - cannot call next()")
    if not iter.finished:
      var item: T
      try:
        item = await genNext()
      except CancelledError as err:
        iter.finish
        raise err
      except CatchableError as err:
        if finishOnErr or isFinished():
          iter.finish
        raise err

      if isFinished():
        iter.finish
      return item
    else:
      raise newException(
        CatchableError, "AsyncIter is finished but next item was requested"
      )

  if isFinished():
    iter.finish

  iter.next = next
  return iter

proc mapAsync*[T, U](iter: Iter[T], fn: Function[T, Future[U]]): AsyncIter[U] =
  # Chain dispose to underlying sync iterator
  AsyncIter[U].new(
    genNext = () => fn(iter.next()),
    isFinished = () => iter.finished(),
    dispose = proc(): Future[void] {.async.} =
      iter.dispose(),
    isDisposed = () => iter.disposed,
  )

proc new*[U, V: Ordinal](_: type AsyncIter[U], slice: HSlice[U, V]): AsyncIter[U] =
  ## Creates new Iter from a slice
  ##

  let iter = Iter[U].new(slice)
  mapAsync[U, U](
    iter,
    proc(i: U): Future[U] {.async.} =
      i,
  )

proc new*[U, V, S: Ordinal](
    _: type AsyncIter[U], a: U, b: V, step: S = 1
): AsyncIter[U] =
  ## Creates new Iter in range a..b with specified step (default 1)
  ##

  let iter = Iter[U].new(a, b, step)
  mapAsync[U, U](
    iter,
    proc(i: U): Future[U] {.async.} =
      i,
  )

proc empty*[T](_: type AsyncIter[T]): AsyncIter[T] =
  ## Creates an empty AsyncIter
  ##

  var disposed = false

  proc genNext(): Future[T] {.raises: [CatchableError].} =
    raise newException(CatchableError, "Next item requested from an empty AsyncIter")

  proc isFinished(): bool =
    true

  proc onDispose(): Future[void] {.async.} =
    disposed = true

  proc isDisposed(): bool =
    disposed

  AsyncIter[T].new(genNext, isFinished, onDispose, isDisposed)

proc map*[T, U](iter: AsyncIter[T], fn: Function[T, Future[U]]): AsyncIter[U] =
  # Chain dispose to underlying iterator
  AsyncIter[U].new(
    genNext = () => iter.next().flatMap(fn),
    isFinished = () => iter.finished,
    dispose = () => iter.dispose(),
    isDisposed = () => iter.disposed,
  )

proc mapFilter*[T, U](
    iter: AsyncIter[T], mapPredicate: Function[T, Future[Option[U]]]
): Future[AsyncIter[U]] {.async: (raises: [CancelledError]).} =
  var nextFutU: Option[Future[U]]

  proc tryFetch(): Future[void] {.async: (raises: [CancelledError]).} =
    nextFutU = Future[U].none
    while not iter.finished:
      let futT = iter.next()
      try:
        if u =? await futT.flatMap(mapPredicate):
          let futU = newFuture[U]("AsyncIter.mapFilterAsync")
          futU.complete(u)
          nextFutU = some(futU)
          break
      except CancelledError as err:
        raise err
      except CatchableError as err:
        let errFut = newFuture[U]("AsyncIter.mapFilterAsync")
        errFut.fail(err)
        nextFutU = some(errFut)
        break

  proc genNext(): Future[U] {.async.} =
    let futU = nextFutU.unsafeGet
    await tryFetch()
    await futU

  proc isFinished(): bool =
    nextFutU.isNone

  await tryFetch()
  # Chain dispose to underlying iterator
  AsyncIter[U].new(
    genNext,
    isFinished,
    dispose = () => iter.dispose(),
    isDisposed = () => iter.disposed,
  )

proc filter*[T](
    iter: AsyncIter[T], predicate: Function[T, Future[bool]]
): Future[AsyncIter[T]] {.async: (raises: [CancelledError]).} =
  proc wrappedPredicate(t: T): Future[Option[T]] {.async.} =
    if await predicate(t):
      some(t)
    else:
      T.none

  # mapFilter already chains dispose to iter
  await mapFilter[T, T](iter, wrappedPredicate)

proc delayBy*[T](iter: AsyncIter[T], d: Duration): AsyncIter[T] =
  ## Delays emitting each item by given duration
  ##

  # map already chains dispose to iter
  map[T, T](
    iter,
    proc(t: T): Future[T] {.async.} =
      await sleepAsync(d)
      t,
  )
