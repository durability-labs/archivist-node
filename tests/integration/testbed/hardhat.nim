import pkg/chronos
import ../hardhatprocess
import ./testbed

type HardhatCommand = ref object
  testbed: Testbed

func hardhat*(testbed: Testbed): HardhatCommand =
  HardhatCommand(testbed: testbed)

proc start*(command: HardhatCommand) {.async.} =
  let process = await HardhatProcess.startNode(args = @[], name = "hardhat")
  command.testbed.hardhatProcess = some process

proc stop*(command: HardhatCommand) {.async.} =
  if process =? command.testbed.hardhatProcess:
    await process.stop()
    command.testbed.hardhatProcess = HardhatProcess.none