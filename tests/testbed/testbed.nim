import std/os
import std/times
import pkg/chronos
import pkg/ethers
import pkg/questionable
import ./network/hardhat
import ./network/node
import ./helpers/project
import ./error

type Testbed* = ref object
  startedAt: DateTime
  hardhatInstance: ?Hardhat
  nodeInstances: seq[Node]
  providerInstance: ?JsonRpcProvider

func `hardhatInstance=`*(testbed: Testbed, hardhat: Hardhat) =
  if testbed.hardhatInstance.isSome:
    raise newException(TestbedError, "hardhat already started")
  testbed.hardhatInstance = some hardhat

func hardhatInstance*(testbed: Testbed): Hardhat =
  without hardhat =? testbed.hardhatInstance:
    raise newException(TestbedError, "hardhat is not running")
  hardhat

proc provider*(testbed: Testbed): JsonRpcProvider =
  without var provider =? testbed.providerInstance:
    provider = JsonRpcProvider.new(testbed.hardhatInstance().jsonRpcUrl)
    testbed.providerInstance = some provider
  provider

func nodeInstances*(testbed: Testbed): var seq[Node] =
  testbed.nodeInstances

func logDir*(testbed: Testbed): string =
  let timestamp = testbed.startedAt.format("yyyy-MM-dd-HH-mm-ss")
  projectRoot / "logs" / "testbed" / timestamp

proc start*(_: type Testbed): Future[Testbed] {.async.} =
  Testbed(startedAt: now())

proc stop*(testbed: Testbed) {.async.} =
  if provider =? testbed.providerInstance:
    await provider.close()
    testbed.providerInstance = none JsonRpcProvider
  while testbed.nodeInstances.len > 0:
    let node = testbed.nodeInstances.pop()
    await node.stop()
    node.deleteDataDir()
  if hardhat =? testbed.hardhatInstance:
    await hardhat.stop()
    testbed.hardhatInstance = none Hardhat
