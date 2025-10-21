import std/os
import pkg/chronos
import pkg/questionable
import pkg/ethers
import ../network/hardhat
import ../testbed

type HardhatBuilder = ref object
  testbed: Testbed
  logToFile: bool

func hardhat*(testbed: Testbed): HardhatBuilder =
  HardhatBuilder(testbed: testbed)

func log*(builder: HardhatBuilder): HardhatBuilder =
  builder.logToFile = true
  builder

proc logFile(builder: HardhatBuilder): ?string =
  if builder.logToFile or getEnv("CI") == "true":
    let logDir = builder.testbed.logDir
    createDir(logDir)
    some logDir / "hardhat.log"
  else:
    none string

proc start*(builder: HardhatBuilder): Future[Hardhat] {.async.} =
  let hardhat = await Hardhat.start(logFile = builder.logFile)
  builder.testbed.hardhatInstance = hardhat
  let provider = await JsonRpcProvider.connect(hardhat.jsonRpcUrl)
  builder.testbed.provider = provider
  hardhat
