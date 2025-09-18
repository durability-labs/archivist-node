import std/times
import pkg/chronos
import pkg/ethers
import archivist/contracts/clock
import ../testbed
import ../asynctest

suite "On-Chain Clock":
  var testbed: Testbed
  var hardhat: Hardhat

  setupAll:
    testbed = await Testbed.start()
    hardhat = await testbed.hardhat.start()

  teardownAll:
    await testbed.stop()

  var clock: OnChainClock

  setup:
    clock = OnChainClock.new(testbed.eth.provider)
    await clock.start()

  teardown:
    await clock.stop()
    await hardhat.reset()

  test "returns the current time of the EVM":
    let blockTime = await testbed.eth.time.blockTime(BlockTag.latest)
    check clock.now() == blockTime.int64

  test "updates time with timestamp of new blocks":
    let future = (getTime() + 42.years).toUnix
    await testbed.eth.time.advanceTo(future.uint64)
    check eventually clock.now() >= future

  test "can wait until a certain time is reached by the chain":
    let future = clock.now() + 42 # seconds
    let waiting = clock.waitUntil(future)
    await testbed.eth.time.advanceTo(future.uint64)
    check await waiting.withTimeout(chronos.milliseconds(500))

  test "can wait until a certain time is reached by the wall-clock":
    let future = clock.now() + 1 # seconds
    let waiting = clock.waitUntil(future)
    check await waiting.withTimeout(chronos.seconds(2))

  test "handles starting multiple times":
    await clock.start()
    await clock.start()

  test "handles stopping multiple times":
    await clock.stop()
    await clock.stop()
