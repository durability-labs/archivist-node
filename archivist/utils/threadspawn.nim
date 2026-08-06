## Copyright (c) 2025 Archivist Authors
## Licensed under either of
##  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## Convenience wrappers for bridging taskpools thread spawn to Chronos async.
##
## The two pain points these wrappers eliminate:
##
## 1. **Signal lifecycle boilerplate.** Every call site repeats the same
##    ThreadSignalPtr.new / defer-close / wait / cancellation-safe-join dance.
##    ``withThreadSignal`` handles signal create+destroy; ``awaitSpawn`` handles
##    the cancellation-safe join.
## 2. **Result transfer.** Workers write results into ``ctx[].result`` via
##    ``unsafeIsolate(move result)`` and ``spawnJoin`` extracts it after
##    awaiting.  ``TaskCtx[T]`` uses a ``SharedPtr`` so the ctx can be passed
##    to the worker by pointer and cleaned up via atomic refcounting.
##
## Usage by pattern:
##
## **Custom task struct** (erasure, nimgroth16, nat-traversal):
##
##   .. code-block:: nim
##      withThreadSignal(sig):
##        var task = MyTask(data: data, signal: sig)
##        tp.spawn myWorker(addr task)
##        ?await awaitSpawn(sig.wait())
##        if not task.success.load: return failure("task failed")
##
## **Generic result** (kvstore-style):
##
##   .. code-block:: nim
##      let value = ?await spawnJoin[MyResultType]:
##        proc(ctx: SharedPtr[TaskCtx[MyResultType]]) {.gcsafe.} =
##          tp.spawn myWorker(ctx, args)
##
## Backend abstraction: ``spawnJoin`` takes a spawn callback, not a
## ``Taskpool``, so any backend that can run a proc and fire a
## ``ThreadSignalPtr`` works.  Only ``awaitSpawn`` uses chronos internals
## (``join`` / ``noCancel``), which are backend-independent.
##
## Multi-spawn note: ``spawnJoin`` covers the single-spawn-then-await
## majority.  For parallel loops (e.g. kvstore ``getImpl`` chunked reads), use
## ``withThreadSignal`` per spawn, collect futures, and ``awaitSpawn`` each.

{.push raises: [].}

when not compileOption("threads"):
  {.error: "threadspawn requires -threads:on".}

import std/isolation

import pkg/chronos
import pkg/chronos/threadsync
import pkg/chronicles
import pkg/questionable/results
import pkg/threading/smartptrs

import ../errors

export isolation
export threadsync
export smartptrs

logScope:
  topics = "archivist threadspawn"

type
  SpawnFut* = Future[void].Raising([AsyncError, CancelledError])
    ## The future returned by ``ThreadSignalPtr.wait``.

  OnSpawnError* = proc() {.async: (raises: []).}
    ## Optional cleanup callback invoked when a spawned task fails or is
    ## cancelled, before the noCancel drain.  Use it to flip ``finished``
    ## flags or release resources the worker might be waiting on.
    ##
    ## Must not raise - a cancelled cleanup callback would hit Chronos'
    ## ``noCancel`` ``raiseAssert`` and convert a cancellation into a Defect.

  ThreadSpawnRes*[T] = Result[T, string]
    ## Thread safe result type
    ##
    ## The error is an owned string so the message stays valid after the
    ## worker's scope ends

  TaskCtx*[T] = object
    ## Per-task state for cross-thread communication with generic results.
    ##
    ## ``signal``: completion notification (fired by the worker via
    ## ``fireSync``).
    ## ``result``: output value wrapped in ``Isolated`` for thread-safe
    ## transfer.  Workers must assign with ``unsafeIsolate(move result)`` to
    ## move the result rather than copy it.
    ##
    ## Memory management: use ``SharedPtr[TaskCtx[T]]`` so atomic refcounting
    ## handles cleanup.  The ``SharedPtr`` passes through ``toTask``'s
    ## ``isolate`` as a single pointer move.
    signal*: ThreadSignalPtr
    result*: Isolated[ThreadSpawnRes[T]]

template mapThreadSpawnErr*[T, V](exp: Result[T, V]): ThreadSpawnRes[T] =
  ## Convert `Result[T, E]` to `Result[T, string]`.
  ##
  ## The message is copied into an owned string, so it stays valid after the
  ## worker's scope ends.

  exp.mapErr(
    proc(e: V): string =
      when typeof(e) is (ref Exception):
        e.msg
      else:
        mixin `$`
        $e
  )

proc awaitSpawn*(
    taskFut: SpawnFut, onError: OnSpawnError = nil
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Cancellation-safe wait for a spawned task to complete.
  ##
  ## ``taskFut`` is the future returned by ``ThreadSignalPtr.wait``.
  ## Uses ``join()`` + ``noCancel`` so that cancelling this future does NOT
  ## cancel the underlying worker - the worker runs to completion before we
  ## return, preventing use-after-free of heap-allocated task data.
  ##
  ## On cancellation: re-raises ``CancelledError`` after the worker finishes.
  ## On other errors: optionally calls ``onError``, then returns the failure.
  ##
  ## Signal lifecycle is NOT handled here - the caller (typically via
  ## ``withThreadSignal`` or ``spawnJoin``) owns ``signal.close`` via defer.
  ##

  let joinFut = taskFut.join()

  if err =? catch(await joinFut).errorOption:
    if not onError.isNil:
      await noCancel onError()

    # Must wait for worker to finish before returning - without this the
    # caller could free heap-allocated ctx/task while the worker is still
    # writing to it.
    ?catch(await noCancel taskFut)
    if err of CancelledError:
      raise (ref CancelledError)(err)
    return failure(err)

  # join() completes unconditionally and does not forward the source future's
  # error.  If taskFut itself failed (e.g. register2/addReader2 in
  # ThreadSignalPtr.wait), return the error rather than reporting success
  # with an unwritten result.
  if taskFut.failed():
    return failure(taskFut.error())

  success()

{.pop.} # templates splice into caller scope; their raises are checked there

template withThreadSignal*(signalName, body: untyped) =
  ## Create a ``ThreadSignalPtr``, bind it to ``signalName``, and run ``body``
  ## inside a ``block`` with ``signal.close`` deferred.
  ##
  ## Designed for custom task structs where the caller reads typed fields
  ## (e.g. ``Atomic[bool]``) after awaiting.  Everything - spawn, await, and
  ## result extraction - lives inside the block, so task variables are
  ## properly scoped and don't leak into the enclosing proc.
  ##
  ## ``signalName`` is caller-chosen so it cannot collide with existing variables.
  ##
  ##   .. code-block:: nim
  ##      withThreadSignal(sig):
  ##        var task = MyTask(signal: sig, ...)
  ##        tp.spawn myWorker(addr task)
  ##        ?await awaitSpawn(sig.wait())
  ##        if not task.ok.load: return failure("task failed")
  ##
  ## The defer runs on ALL exit paths (early return, exception propagation),
  ## so the signal fd is never leaked - even on cancellation.
  ##
  block:
    let signalName {.inject.} = ?ThreadSignalPtr.new().mapFailure
    defer:
      if closeErr =? signalName.close().errorOption:
        warn "Failed to close thread signal", error = closeErr
    body

type SpawnFn*[T] = proc(ctx: SharedPtr[TaskCtx[T]]) {.gcsafe, raises: [].}
  ## Callback that receives the ctx and spawns the worker.
  ## Must call ``tp.spawn worker(ctx, ...)`` inside.
  ##
  ## ``raises: []`` prevents a callback exception from unwinding ``spawnJoin``'s
  ## signal-close defer while the queued worker still holds the signal.

proc spawnJoin*[T](
    spawnFn: SpawnFn[T], onError: OnSpawnError = nil
): Future[?!T] {.async: (raises: [CancelledError]).} =
  ## Create a ``ThreadSignalPtr`` + ``SharedPtr[TaskCtx[T]]``, spawn the worker,
  ## await completion, close the signal, and extract the result.
  ##
  ## ``spawnFn`` receives the ctx and must spawn the worker (e.g.
  ## ``tp.spawn worker(ctx, ...)``).  The callback runs on the calling thread
  ## before the first await, so any backend that can run a proc and fire a
  ## ``ThreadSignalPtr`` works.  Workers write results with:
  ## ``ctx[].result = unsafeIsolate(move result)``
  ##
  ## ``onError`` is invoked if the await fails or is cancelled, before the
  ## noCancel drain (use it to flip ``finished`` flags etc).
  ##
  ## Signal lifecycle (create/close) is fully encapsulated -- the caller never
  ## touches ``ThreadSignalPtr``.  The defer runs on ALL exit paths, so the
  ## signal fd is never leaked.
  ##
  ## Example:
  ##
  ##   .. code-block:: nim
  ##      let keys = ?await spawnJoin[seq[Key]]:
  ##        proc(ctx: SharedPtr[TaskCtx[seq[Key]]]) {.gcsafe.} =
  ##          self.tp.spawn runHasTaskMany(ctx, paths)
  withThreadSignal(sig):
    let ctx = newSharedPtr(TaskCtx[T](signal: sig))
    let taskFut = sig.wait()
    if taskFut.failed():
      return failure(taskFut.error())
    spawnFn(ctx)
    ?await awaitSpawn(taskFut, onError)
    success ?extract(ctx[].result).mapFailure
