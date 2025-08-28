import pkg/chronos
import pkg/ethers
import pkg/questionable
import ./hardhat
import ./node

type Testbed* = ref object
  hardhatInstance: ?Hardhat
  nodeInstances: seq[Node]
  providerInstance: ?Provider

func hardhatInstance*(testbed: Testbed): var Option[Hardhat] =
  testbed.hardhatInstance

func providerInstance*(testbed: Testbed): var Option[Provider] =
  testbed.providerInstance

func nodeInstances*(testbed: Testbed): var seq[Node] =
  testbed.nodeInstances

proc start*(_: type Testbed): Future[Testbed] {.async.} =
  Testbed()

proc stop*(testbed: Testbed) {.async.} =
  if provider =? testbed.providerInstance:
    await provider.close()
    testbed.providerInstance = none Provider
  while testbed.nodeInstances.len > 0:
    let node = testbed.nodeInstances.pop()
    await node.stop()
  if hardhat =? testbed.hardhatInstance:
    await hardhat.stop()
    testbed.hardhatInstance = none Hardhat
