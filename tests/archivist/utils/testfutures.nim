import pkg/chronos
import pkg/archivist/utils/futures

import ../../asynctest

type WrapTestError = object of CatchableError

suite "Future wrappers":
  test "Should preserve plain future type":
    let
      source = Future[int].init("source")
      wrapped: Future[int] = source.wrap()

    source.complete(42)
    check (await wrapped) == 42

  test "Should mirror plain future completion":
    let
      source = Future[int].init("source")
      wrapped = source.wrap()

    source.complete(42)
    check (await wrapped) == 42

  test "Should mirror plain future failure":
    let
      source = Future[int].init("source")
      wrapped = source.wrap()

    source.fail(newException(WrapTestError, "boom"))
    expect WrapTestError:
      discard await wrapped

  test "Should mirror plain future source cancellation":
    let
      source = Future[int].init("source")
      wrapped = source.wrap()

    await source.cancelAndWait()
    check wrapped.cancelled

  test "Should not cancel plain source from wrapper cancellation":
    let
      source = Future[int].init("source")
      wrapped = source.wrap()

    await wrapped.cancelAndWait()
    check wrapped.cancelled
    check not source.finished

    source.complete(42)
    check source.finished

  test "Should preserve raises-aware future type":
    type TestFuture = Future[int].Raising([CancelledError, WrapTestError])
    let
      source = TestFuture.init("source")
      wrapped: TestFuture = source.wrap()

    source.complete(42)
    check (await wrapped) == 42

  test "Should mirror completion":
    let
      source = Future[int].Raising([CancelledError, WrapTestError]).init("source")
      wrapped = source.wrap()

    source.complete(42)
    check (await wrapped) == 42

  test "Should mirror failure":
    let
      source = Future[int].Raising([CancelledError, WrapTestError]).init("source")
      wrapped = source.wrap()

    source.fail(newException(WrapTestError, "boom"))
    expect WrapTestError:
      discard await wrapped

  test "Should mirror source cancellation":
    let
      source = Future[int].Raising([CancelledError, WrapTestError]).init("source")
      wrapped = source.wrap()

    await source.cancelAndWait()
    check wrapped.cancelled

  test "Should not cancel source from wrapper cancellation":
    let
      source = Future[int].Raising([CancelledError, WrapTestError]).init("source")
      wrapped = source.wrap()

    await wrapped.cancelAndWait()
    check wrapped.cancelled
    check not source.finished

    source.complete(42)
    check source.finished
