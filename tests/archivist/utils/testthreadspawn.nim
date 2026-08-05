import std/atomics

import pkg/chronos
import pkg/chronicles
import pkg/taskpools
import pkg/questionable/results

import archivist/utils/threadspawn

import ../../asynctest

type ToyTask = object
  value: int
  ok: Atomic[bool]
  signal: ThreadSignalPtr

proc toyWorker(task: ptr ToyTask) {.gcsafe.} =
  task[].ok.store(true)
  discard task[].signal.fireSync()

proc toyFailingWorker(task: ptr ToyTask) {.gcsafe.} =
  task[].ok.store(false)
  discard task[].signal.fireSync()

proc toySlowWorker(task: ptr ToyTask) {.gcsafe.} =
  # Write to the atomic on each iteration so the optimizer cannot remove
  # the loop.  The loop count is large enough to keep the worker running
  # while the awaiter cancels.
  for i in 0 ..< 100_000_000:
    task[].ok.store(false)
  task[].ok.store(true)
  discard task[].signal.fireSync()

suite "threadspawn wrappers":
  var tp: Taskpool

  setup:
    tp = Taskpool.new(numThreads = 2)

  teardown:
    tp.shutdown()

  test "withThreadSignal + awaitSpawn returns on success":
    proc runTest(): Future[?!void] {.async: (raises: [CancelledError]).} =
      withThreadSignal(sig):
        var task = ToyTask(value: 42, signal: sig)
        tp.spawn toyWorker(addr task)
        ?await awaitSpawn(sig.wait())
        check task.ok.load()
      success()

    (await runTest()).tryGet()

  test "withThreadSignal + awaitSpawn propagates failure flag":
    proc runTest(): Future[?!void] {.async: (raises: [CancelledError]).} =
      withThreadSignal(sig):
        var task = ToyTask(value: 42, signal: sig)
        tp.spawn toyFailingWorker(addr task)
        ?await awaitSpawn(sig.wait())
        check not task.ok.load()
      success()

    (await runTest()).tryGet()

  test "spawnJoin extracts generic result":
    proc runIntTask(ctx: SharedPtr[TaskCtx[int]]) {.gcsafe.} =
      var r = ThreadSpawnRes[int].ok(123)
      ctx[].result = unsafeIsolate(move r)
      discard ctx[].signal.fireSync()

    proc runTest(): Future[?!void] {.async: (raises: [CancelledError]).} =
      let value = ?await spawnJoin[int](runIntTask)
      check value == 123
      success()

    (await runTest()).tryGet()

  test "spawnJoin extracts error result":
    proc runErrTask(ctx: SharedPtr[TaskCtx[int]]) {.gcsafe.} =
      var r = ThreadSpawnRes[int].err("boom")
      ctx[].result = unsafeIsolate(move r)
      discard ctx[].signal.fireSync()

    proc runTest(): Future[?!void] {.async: (raises: [CancelledError]).} =
      let result = await spawnJoin[int](runErrTask)
      check result.isErr
      check result.error.msg == "boom"
      success()

    (await runTest()).tryGet()

  test "spawnJoin with seq result (move, not copy)":
    proc runSeqTask(ctx: SharedPtr[TaskCtx[seq[int]]]) {.gcsafe.} =
      var r = ThreadSpawnRes[seq[int]].ok(@[1, 2, 3, 4, 5])
      ctx[].result = unsafeIsolate(move r)
      discard ctx[].signal.fireSync()

    proc runTest(): Future[?!void] {.async: (raises: [CancelledError]).} =
      let value = ?await spawnJoin[seq[int]](runSeqTask)
      check value == @[1, 2, 3, 4, 5]
      success()

    (await runTest()).tryGet()

  test "awaitSpawn cancellation drains worker before returning":
    proc runTest(): Future[?!void] {.async: (raises: [CancelledError]).} =
      withThreadSignal(sig):
        var task = ToyTask(value: 99, signal: sig)
        tp.spawn toySlowWorker(addr task)
        let spawnFut = awaitSpawn(sig.wait())

        # Give the worker time to start, then cancel
        await sleepAsync(1.millis)
        await spawnFut.cancelAndWait()

        # awaitSpawn should report cancellation
        check spawnFut.cancelled()

        # The noCancel drain must have waited for the worker to finish
        # before returning -- task is still valid because the signal
        # close defer hasn't freed it yet.
        check task.ok.load()
      success()

    (await runTest()).tryGet()
