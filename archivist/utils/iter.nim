## Iter[T] - Synchronous iterator with mandatory disposal
##
## USAGE CONTRACT:
## 1. Single-consumer: Do NOT call next() concurrently from multiple threads/tasks
## 2. Disposal required: Always call dispose() when done (use defer or try/finally)
## 3. No concurrent dispose: Do NOT call dispose() while next() is in-flight
## 4. After dispose: Calling next() will raise an error
##
## Example:
##   let iter = createIterator()
##   defer: iter.dispose()
##   while not iter.finished:
##     let item = iter.next()
##     # process item

import std/sugar

import pkg/questionable
import pkg/questionable/results

type
  Function*[T, U] = proc(fut: T): U {.raises: [CatchableError], gcsafe, closure.}
  IsFinished* = proc(): bool {.raises: [], gcsafe, closure.}
  IsDisposed* = proc(): bool {.raises: [], gcsafe, closure.}
  Dispose* = proc() {.raises: [], gcsafe, closure.}
  GenNext*[T] = proc(): T {.raises: [CatchableError], gcsafe.}
  Iterator[T] = iterator (): T

  IterObj[T] = object
    finished: bool
    next*: GenNext[T]
    disposeImpl: Dispose
    disposedImpl: IsDisposed

  Iter*[T] = ref IterObj[T]

# Note: We intentionally don't use =destroy to auto-dispose because closures
# captured in disposeImpl might reference objects that are garbage collected
# before the Iter itself. Callers MUST call dispose() explicitly.

proc finish*[T](self: Iter[T]): void =
  self.finished = true

proc finished*[T](self: Iter[T]): bool =
  self.finished

proc disposed*[T](self: Iter[T]): bool =
  self.disposedImpl()

proc dispose*[T](self: Iter[T]) =
  ## Dispose the iterator and release any underlying resources.
  ## Caller is responsible for calling this when done with the iterator.
  ## Idempotent - safe to call multiple times.
  ## Sets finished = true to prevent further iteration.
  if not self.disposed:
    self.finished = true
    self.disposeImpl()

iterator items*[T](self: Iter[T]): T =
  while not self.finished:
    yield self.next()

iterator pairs*[T](self: Iter[T]): tuple[key: int, val: T] {.inline.} =
  var i = 0
  while not self.finished:
    yield (i, self.next())
    inc(i)

proc new*[T](
    _: type Iter[T],
    genNext: GenNext[T],
    isFinished: IsFinished,
    dispose: Dispose,
    isDisposed: IsDisposed,
    finishOnErr: bool = true,
): Iter[T] =
  ## Creates a new Iter using elements returned by supplier function `genNext`.
  ## Iter is finished whenever `isFinished` returns true.
  ## Caller is responsible for calling `dispose()` when done with the iterator.
  ##
  ## IMPORTANT: dispose and isDisposed callbacks are REQUIRED - passing nil will assert.

  doAssert dispose != nil, "dispose callback is required"
  doAssert isDisposed != nil, "isDisposed callback is required"

  var iter = Iter[T](disposeImpl: dispose, disposedImpl: isDisposed)

  proc next(): T {.raises: [CatchableError].} =
    if iter.disposed:
      raise newException(CatchableError, "Iter is disposed - cannot call next()")
    if not iter.finished:
      var item: T
      try:
        item = genNext()
      except CatchableError as err:
        if finishOnErr or isFinished():
          iter.finish
        raise err

      if isFinished():
        iter.finish
      return item
    else:
      raise newException(CatchableError, "Iter is finished but next item was requested")

  if isFinished():
    iter.finish

  iter.next = next
  return iter

proc new*[U, V, S: Ordinal](_: type Iter[U], a: U, b: V, step: S = 1): Iter[U] =
  ## Creates a new Iter in range a..b with specified step (default 1)
  ##

  var
    i = a
    disposed = false

  proc genNext(): U =
    let u = i
    inc(i, step)
    u

  proc isFinished(): bool =
    (step > 0 and i > b) or (step < 0 and i < b)

  proc onDispose() =
    disposed = true

  proc isDisposed(): bool =
    disposed

  Iter[U].new(genNext, isFinished, onDispose, isDisposed)

proc new*[U, V: Ordinal](_: type Iter[U], slice: HSlice[U, V]): Iter[U] =
  ## Creates a new Iter from a slice
  ##

  Iter[U].new(slice.a.int, slice.b.int, 1)

proc new*(T: type Iter[int], slice: HSlice[int, int], start: int): Iter[int] =
  ## Creates a circular Iter from an int slice, starting at `start` and
  ## wrapping around to the slice's first element after reaching its last.
  ## Every element of the slice is yielded exactly once. `start` must lie
  ## within the slice.
  ##

  var
    i = start
    wrapped = false
    disposed = false

  let
    a = slice.a
    b = slice.b

  doAssert (i >= a and i <= b) or a > b, "start must lie within the slice"

  proc genNext(): int =
    let u = i
    inc(i)
    if i > b:
      i = a
      wrapped = true
    u

  proc isFinished(): bool =
    a > b or (wrapped and i >= start)

  proc onDispose() =
    disposed = true

  proc isDisposed(): bool =
    disposed

  T.new(genNext, isFinished, onDispose, isDisposed)

proc new*[T](_: type Iter[T], items: seq[T]): Iter[T] =
  ## Creates a new Iter from a sequence
  ##

  Iter[int].new(0 ..< items.len).map((i: int) => items[i])

proc new*[T](_: type Iter[T], iter: Iterator[T]): Iter[T] =
  ## Creates a new Iter from an iterator
  ##
  var
    nextOrErr: Option[?!T]
    disposed = false

  proc tryNext(): void =
    nextOrErr = none(?!T)
    while not iter.finished:
      try:
        let t: T = iter()
        if not iter.finished:
          nextOrErr = some(success(t))
        break
      except CatchableError as err:
        nextOrErr = some(T.failure(err))

  proc genNext(): T {.raises: [CatchableError].} =
    if nextOrErr.isNone:
      raise newException(CatchableError, "Iterator finished but genNext was called")

    without u =? nextOrErr.unsafeGet, err:
      raise err

    tryNext()
    return u

  proc isFinished(): bool =
    nextOrErr.isNone

  proc onDispose() =
    disposed = true

  proc isDisposed(): bool =
    disposed

  tryNext()
  Iter[T].new(genNext, isFinished, onDispose, isDisposed)

proc empty*[T](_: type Iter[T]): Iter[T] =
  ## Creates an empty Iter
  ##

  var disposed = false

  proc genNext(): T {.raises: [CatchableError].} =
    raise newException(CatchableError, "Next item requested from an empty Iter")

  proc isFinished(): bool =
    true

  proc onDispose() =
    disposed = true

  proc isDisposed(): bool =
    disposed

  Iter[T].new(genNext, isFinished, onDispose, isDisposed)

proc map*[T, U](iter: Iter[T], fn: Function[T, U]): Iter[U] =
  # Chain dispose to underlying iterator
  Iter[U].new(
    genNext = () => fn(iter.next()),
    isFinished = () => iter.finished,
    dispose = () => iter.dispose(),
    isDisposed = () => iter.disposed,
  )

proc mapFilter*[T, U](iter: Iter[T], mapPredicate: Function[T, Option[U]]): Iter[U] =
  var nextUOrErr: Option[?!U]

  proc tryFetch(): void =
    nextUOrErr = none(?!U)
    while not iter.finished:
      try:
        let t = iter.next()
        if u =? mapPredicate(t):
          nextUOrErr = some(success(u))
          break
      except CatchableError as err:
        nextUOrErr = some(U.failure(err))

  proc genNext(): U {.raises: [CatchableError].} =
    if nextUOrErr.isNone:
      raise newException(CatchableError, "Iterator finished but genNext was called")

    # at this point nextUOrErr should always be some(..)
    without u =? nextUOrErr.unsafeGet, err:
      raise err

    tryFetch()
    return u

  proc isFinished(): bool =
    nextUOrErr.isNone

  tryFetch()
  # Chain dispose to underlying iterator
  Iter[U].new(
    genNext,
    isFinished,
    dispose = () => iter.dispose(),
    isDisposed = () => iter.disposed,
  )

proc filter*[T](iter: Iter[T], predicate: Function[T, bool]): Iter[T] =
  proc wrappedPredicate(t: T): Option[T] =
    if predicate(t):
      some(t)
    else:
      T.none

  mapFilter[T, T](iter, wrappedPredicate)
