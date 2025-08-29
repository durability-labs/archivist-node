import std/os
import std/times
import pkg/chronos
import pkg/ethers
import pkg/questionable
import ./network/hardhat
import ./network/node
import ./helpers/project

type Testbed* = ref object
  startedAt: DateTime
  hardhatInstance: ?Hardhat
  nodeInstances: seq[Node]
  providerInstance: ?Provider

func hardhatInstance*(testbed: Testbed): var Option[Hardhat] =
  testbed.hardhatInstance

func providerInstance*(testbed: Testbed): var Option[Provider] =
  testbed.providerInstance

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
    testbed.providerInstance = none Provider
  while testbed.nodeInstances.len > 0:
    let node = testbed.nodeInstances.pop()
    await node.stop()
  if hardhat =? testbed.hardhatInstance:
    await hardhat.stop()
    testbed.hardhatInstance = none Hardhat
