import std/strutils
import std/json
import pkg/chronos
import pkg/ethers
import pkg/questionable
import ../testbed

type EthBuilder = ref object
  testbed: Testbed

func eth*(testbed: Testbed): EthBuilder =
  EthBuilder(testbed: testbed)

func provider*(builder: EthBuilder): JsonRpcProvider =
  builder.testbed.provider

type TimeBuilder = ref object
  testbed: Testbed

func time*(eth: EthBuilder): TimeBuilder =
  TimeBuilder(testbed: eth.testbed)

proc blockTime*(builder: TimeBuilder, tag: BlockTag): Future[uint64] {.async.} =
  let provider = builder.testbed.provider
  let blck = !await provider.getBlock(BlockTag.pending)
  blck.timestamp.truncate(uint64)

proc now*(builder: TimeBuilder): Future[uint64] {.async.} =
  await builder.blockTime(BlockTag.pending)

proc advance*(builder: TimeBuilder, seconds: uint64) {.async.} =
  let provider = builder.testbed.provider
  discard await provider.send("evm_increaseTime", @[%("0x" & seconds.toHex)])
  discard await provider.send("evm_mine")

proc advanceTo*(builder: TimeBuilder, timestamp: uint64) {.async.} =
  if (await builder.now()) == timestamp:
    return
  let provider = builder.testbed.provider
  discard await provider.send("evm_setNextBlockTimestamp", @[%("0x" & timestamp.toHex)])
  discard await provider.send("evm_mine")
