import std/strutils
import std/json
import pkg/chronos
import pkg/ethers
import ../testbed

type TimeBuilder = ref object
  testbed: Testbed

func time*(testbed: Testbed): TimeBuilder =
  TimeBuilder(testbed: testbed)

proc advance*(builder: TimeBuilder, seconds: int) {.async.} =
  let provider = builder.testbed.provider
  discard await provider.send("evm_increaseTime", @[%("0x" & seconds.toHex)])
  discard await provider.send("evm_mine")
