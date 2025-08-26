import pkg/chronos
import pkg/questionable
import ./hardhat
import ./node

type TestbedError* = object of CatchableError

type Testbed* = ref object
  hardhatInstance: ?Hardhat
  nodeInstances: seq[Node]

func hardhatInstance*(testbed: Testbed): var Option[Hardhat] =
  testbed.hardhatInstance

func nodeInstances*(testbed: Testbed): var seq[Node] =
  testbed.nodeInstances

proc start*(_: type Testbed): Future[Testbed] {.async.} =
  Testbed()

proc stop*(testbed: Testbed) {.async.} =
  if hardhat =? testbed.hardhatInstance:
    await hardhat.stop()
    testbed.hardhatInstance = none Hardhat
  while testbed.nodeInstances.len > 0:
    let node = testbed.nodeInstances.pop()
    await node.stop()
