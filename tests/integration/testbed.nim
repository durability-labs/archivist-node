import pkg/chronos
import ./testbed/testbed
import ./testbed/hardhat
import ./testbed/nodes
import ./testbed/requests

export testbed.Testbed
export hardhat.hardhat
export hardhat.start
export hardhat.stop
export nodes.node
export nodes.nodes
export nodes.provider
export nodes.failProofs
export nodes.start
export requests.request
export requests.start

proc start*(_: type Testbed): Future[Testbed] {.async.} =
  Testbed()

proc stop*(testbed: Testbed) {.async.} =
  await testbed.hardhat.stop()
  await testbed.nodes.stop()