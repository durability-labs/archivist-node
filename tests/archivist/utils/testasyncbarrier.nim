import pkg/chronos

import archivist/utils/asyncbarrier

import ../../asynctest

suite "AsyncBarrier":
  test "drain returns immediately when no entries":
    let barrier = AsyncBarrier.new()
    await barrier.drain()
    check barrier.count == 0

  test "single enter and leave":
    let barrier = AsyncBarrier.new()
    barrier.enter()
    check barrier.count == 1
    barrier.leave()
    check barrier.count == 0

  test "multiple enters and leaves":
    let barrier = AsyncBarrier.new()
    barrier.enter()
    barrier.enter()
    barrier.enter()
    check barrier.count == 3
    barrier.leave()
    check barrier.count == 2
    barrier.leave()
    barrier.leave()
    check barrier.count == 0

  test "drain waits for all entries to leave":
    let barrier = AsyncBarrier.new()
    var drained = false

    barrier.enter()
    barrier.enter()

    let drainFut = barrier.drain()
    proc drainCallback() {.async: (raises: []).} =
      try:
        await drainFut
      except CancelledError:
        discard
      drained = true

    let drainTask = drainCallback()

    # drain should not complete yet
    await sleepAsync(1.millis)
    check not drained

    barrier.leave()
    await sleepAsync(1.millis)
    check not drained

    barrier.leave()
    await sleepAsync(1.millis)
    check drained

    await drainTask

  test "drain after all leaves returns immediately":
    let barrier = AsyncBarrier.new()
    barrier.enter()
    barrier.leave()
    # count is 0, drain should return immediately
    await barrier.drain()

  test "multiple drains all wake on leave":
    let barrier = AsyncBarrier.new()
    var
      drained1 = false
      drained2 = false

    barrier.enter()

    proc waiter1() {.async: (raises: []).} =
      try:
        await barrier.drain()
      except CancelledError:
        discard
      drained1 = true

    proc waiter2() {.async: (raises: []).} =
      try:
        await barrier.drain()
      except CancelledError:
        discard
      drained2 = true

    let
      t1 = waiter1()
      t2 = waiter2()

    await sleepAsync(1.millis)
    check not drained1
    check not drained2

    barrier.leave()
    await sleepAsync(1.millis)
    check drained1
    check drained2

    await t1
    await t2

  test "reusable after drain":
    let barrier = AsyncBarrier.new()
    barrier.enter()
    barrier.leave()
    await barrier.drain()

    # use again
    barrier.enter()
    check barrier.count == 1
    barrier.leave()
    check barrier.count == 0
    await barrier.drain()

suite "KeyedBarrier":
  test "independent keys do not interfere":
    let kb = KeyedBarrier[int].new()
    kb.enter(1)
    kb.enter(2)
    check kb.count(1) == 1
    check kb.count(2) == 1

    kb.leave(1)
    check kb.count(1) == 0
    check kb.count(2) == 1
    check 1 notin kb
    check 2 in kb

    kb.leave(2)
    check 2 notin kb

  test "drain per key":
    let kb = KeyedBarrier[int].new()
    var drained = false

    kb.enter(1)
    kb.enter(2)

    proc waiter() {.async: (raises: []).} =
      try:
        await kb.drain(1)
      except CancelledError:
        discard
      drained = true

    let t = waiter()
    await sleepAsync(1.millis)
    check not drained

    # leaving key 2 should not affect key 1
    kb.leave(2)
    await sleepAsync(1.millis)
    check not drained

    kb.leave(1)
    await sleepAsync(1.millis)
    check drained

    await t

  test "drain on absent key returns immediately":
    let kb = KeyedBarrier[int].new()
    await kb.drain(999)

  test "auto-cleanup on leave":
    let kb = KeyedBarrier[int].new()
    kb.enter(42)
    check 42 in kb
    kb.leave(42)
    check 42 notin kb

  test "count for absent key is 0":
    let kb = KeyedBarrier[int].new()
    check kb.count(123) == 0
