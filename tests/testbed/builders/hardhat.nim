import std/os
import pkg/chronos
import pkg/questionable
import ../network/hardhat
import ../testbed
import ../error

type HardhatBuilder = ref object
  testbed: Testbed
  logToFile: bool

func hardhat*(testbed: Testbed): HardhatBuilder =
  HardhatBuilder(testbed: testbed)

func log*(builder: HardhatBuilder): HardhatBuilder =
  builder.logToFile = true
  builder

proc logFile(builder: HardhatBuilder): ?string =
  if builder.logToFile:
    let logDir = builder.testbed.logDir
    createDir(logDir)
    some logDir / "hardhat.log"
  else:
    none string

proc start*(builder: HardhatBuilder): Future[Hardhat] {.async.} =
  if builder.testbed.hardhatInstance.isSome:
    raise newException(TestbedError, "hardhat already started")
  let hardhat = await Hardhat.start()
  builder.testbed.hardhatInstance = some hardhat
  if logFile =? builder.logFile:
    hardhat.logToFile(logFile)
  hardhat
