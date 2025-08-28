import pkg/chronos
import pkg/questionable
import ../testbed
import ../node
import ../hardhat

type
  NodeBuilder = ref object
    testbed: Testbed
    persistence: ? bool
    ethPrivateKey: ? ? string

func node*(testbed: Testbed): NodeBuilder =
  NodeBuilder(testbed: testbed)

func persistence*(builder: NodeBuilder, enabled: bool = true): NodeBuilder =
  builder.persistence = some enabled
  builder

func ethPrivateKey*(builder: NodeBuilder, filename: string): NodeBuilder =
  builder.ethPrivateKey = some some filename
  builder

func noEthPrivateKey*(builder: NodeBuilder): NodeBuilder =
  builder.ethPrivateKey = some none string
  builder

func persistenceResolved(builder: NodeBuilder): bool =
  builder.persistence |? true

func ethPrivateKeyResolved(builder: NodeBuilder): ?string =
  if ethPrivateKey =? builder.ethPrivateKey:
    return ethPrivateKey
  if builder.persistenceResolved:
    if hardhat =? builder.testbed.hardhatInstance:
      return some hardhat.accounts.pop().privateKeyFile
  none string

proc start*(builder: NodeBuilder): Future[Node] {.async.} =
  var arguments: seq[string]
  if builder.persistenceResolved:
    arguments.add("persistence")
  if ethPrivateKey =? builder.ethPrivateKeyResolved:
    arguments.add("--eth-private-key=" & ethPrivateKey)
  let node = await Node.start(arguments).waitForRestApi()
  builder.testbed.nodeInstances.add(node)
  node
