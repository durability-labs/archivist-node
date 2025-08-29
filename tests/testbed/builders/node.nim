import std/os
import pkg/chronos
import pkg/questionable
import ../network/node
import ../network/hardhat
import ../helpers/project
import ../testbed
import ./availability

type
  NodeBuilder = ref object
    testbed: Testbed
    logToFile: bool
    persistence: bool = true
    ethPrivateKey: ? ? string
    hasAvailability: bool

func node*(testbed: Testbed): NodeBuilder =
  NodeBuilder(testbed: testbed)

func log*(builder: NodeBuilder): NodeBuilder =
  builder.logToFile = true
  builder

proc logFile(builder: NodeBuilder): ?string =
  if builder.logToFile:
    let logDir = builder.testbed.logDir
    createDir(logDir)
    let nodeNumber = builder.testbed.nodeInstances.len
    let logFile = logDir / "node-" & $nodeNumber & ".log"
    some logFile
  else:
    none string

func persistence*(builder: NodeBuilder, enabled: bool = true): NodeBuilder =
  builder.persistence = enabled
  builder

func ethPrivateKey*(builder: NodeBuilder, filename: string): NodeBuilder =
  builder.ethPrivateKey = some some filename
  builder

func noEthPrivateKey*(builder: NodeBuilder): NodeBuilder =
  builder.ethPrivateKey = some none string
  builder

func provider*(builder: NodeBuilder): NodeBuilder =
  builder.persistence = true
  builder.hasAvailability = true
  builder

func ethPrivateKeyResolved(builder: NodeBuilder): ?string =
  if ethPrivateKey =? builder.ethPrivateKey:
    return ethPrivateKey
  if builder.persistence:
    if hardhat =? builder.testbed.hardhatInstance:
      return some hardhat.accounts.pop().privateKeyFile
  none string

proc start*(builder: NodeBuilder): Future[Node] {.async.} =
  var arguments: seq[string]
  if logFile =? builder.logFile:
    arguments.add("--log-file=" & logFile)
  if builder.persistence:
    arguments.add("persistence")
  if ethPrivateKey =? builder.ethPrivateKeyResolved:
    arguments.add("--eth-private-key=" & ethPrivateKey)
  let node = await Node.start(arguments).waitForRestApi()
  builder.testbed.nodeInstances.add(node)
  if builder.hasAvailability:
    await builder.testbed.availability.create(node)
  node
