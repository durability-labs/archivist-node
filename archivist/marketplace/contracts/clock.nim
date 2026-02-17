import std/times
import pkg/ethers
import pkg/questionable
import pkg/chronos
import pkg/stint
import ../.. /clock

export clock

logScope:
  topics = "contracts clock"

type OnChainClock* = ref object of Clock
  provider: Provider
  subscription: Subscription
  offset: times.Duration
  blockNumber: UInt256
  started: bool
  newBlock: AsyncEvent

proc new*(_: type OnChainClock, provider: Provider): OnChainClock =
  OnChainClock(provider: provider, newBlock: newAsyncEvent())

proc update(clock: OnChainClock, blck: Block) =
  if number =? blck.number and number > clock.blockNumber:
    let blockTime = initTime(blck.timestamp.truncate(int64), 0)
    let computerTime = getTime()
    clock.offset = blockTime - computerTime
    clock.blockNumber = number
    trace "updated clock",
      blockTime = blck.timestamp, blockNumber = number, offset = clock.offset
    clock.newBlock.fire()

method start*(clock: OnChainClock) {.async.} =
  if clock.started:
    return

  if blck =? await clock.provider.getBlock(BlockTag.latest):
    clock.update(blck)

  proc onBlock(blck: Block) =
    clock.update(blck)

  clock.subscription = await clock.provider.subscribe(onBlock)
  clock.started = true

method stop*(clock: OnChainClock) {.async: (raises: []).} =
  if not clock.started:
    return

  try:
    await noCancel clock.subscription.unsubscribe()
  except ProviderError:
    discard

  clock.started = false

method now*(clock: OnChainClock): SecondsSince1970 =
  doAssert clock.started, "clock should be started before calling now()"
  return toUnix(getTime() + clock.offset)

method waitUntil*(clock: OnChainClock, time: SecondsSince1970) {.async.} =
  while (let difference = time - clock.now(); difference > 0):
    trace "clock waitUntil sleeping",
      targetTime = time, currentTime = clock.now(), difference
    clock.newBlock.clear()
    discard await clock.newBlock.wait().withTimeout(chronos.seconds(difference))
