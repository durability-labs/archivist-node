import pkg/chronos
import ../testbed
import ../node

type NodeBuilder = ref object
  testbed: Testbed

func node*(testbed: Testbed): NodeBuilder =
  NodeBuilder(testbed: testbed)

proc start*(builder: NodeBuilder): Future[Node] {.async.} =
  let node = await Node.start(@[])
  builder.testbed.nodeInstances.add(node)
  node
