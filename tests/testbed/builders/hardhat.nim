import pkg/chronos
import pkg/questionable
import ../testbed
import ../hardhat
import ../error

type HardhatBuilder = ref object
  testbed: Testbed

func hardhat*(testbed: Testbed): HardhatBuilder =
  HardhatBuilder(testbed: testbed)

proc start*(builder: HardhatBuilder): Future[Hardhat] {.async.} =
  if builder.testbed.hardhatInstance.isSome:
    raise newException(TestbedError, "hardhat already started")
  let hardhat = await Hardhat.start()
  builder.testbed.hardhatInstance = some hardhat
  hardhat
