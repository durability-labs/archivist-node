import std/os
import pkg/chronos
import pkg/questionable
import ../network/node
import ../network/hardhat
import ../network/hardhat/root
import ../helpers/project
import ../testbed
import ./availability

type
  NodeBuilder = ref object
    testbed: Testbed
    logToFile: bool
    persistence: bool = true
    ethPrivateKey: ? ? string
    prover: bool
    circomR1cs: ?string
    circomWasm: ?string
    circomZkey: ?string
    failProofs: ?int
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
  builder.prover = true
  builder.hasAvailability = true
  builder

func failProofs*(builder: NodeBuilder, every: int): NodeBuilder =
  builder.failProofs = some every
  builder

func ethPrivateKeyResolved(builder: NodeBuilder): ?string =
  if ethPrivateKey =? builder.ethPrivateKey:
    return ethPrivateKey
  if builder.persistence:
    if hardhat =? builder.testbed.hardhatInstance:
      return some hardhat.accounts.pop().privateKeyFile
  none string

const circuitsDir = hardhatRoot / "verifier" / "networks" / "hardhat"

func circomR1csResolved(builder: NodeBuilder): ?string =
  if circomR1cs =? builder.circomR1cs:
    return some circomR1cs
  if builder.prover:
    return some circuitsDir / "proof_main.r1cs"

func circomWasmResolved(builder: NodeBuilder): ?string =
  if circomWasm =? builder.circomWasm:
    return some circomWasm
  if builder.prover:
    return some circuitsDir / "proof_main.wasm"

func circomZkeyResolved(builder: NodeBuilder): ?string =
  if circomZkey =? builder.circomZkey:
    return some circomZkey
  if builder.prover:
    return some circuitsDir / "proof_main.zkey"

proc start*(builder: NodeBuilder): Future[Node] {.async.} =
  var arguments: seq[string]
  if logFile =? builder.logFile:
    arguments.add("--log-file=" & logFile)
  if builder.persistence:
    arguments.add("persistence")
  if ethPrivateKey =? builder.ethPrivateKeyResolved:
    arguments.add("--eth-private-key=" & ethPrivateKey)
  if builder.prover:
    arguments.add("prover")
  if circomR1cs =? builder.circomR1csResolved:
    arguments.add("--circom-r1cs=" & circomR1cs)
  if circomWasm =? builder.circomWasmResolved:
    arguments.add("--circom-wasm=" & circomWasm)
  if circomZkey =? builder.circomZkeyResolved:
    arguments.add("--circom-zkey=" & circomZkey)
  if failProofs =? builder.failProofs:
    arguments.add("--simulate-proof-failures=" & $failProofs)
  let node = await Node.start(arguments).waitForRestApi()
  builder.testbed.nodeInstances.add(node)
  if builder.hasAvailability:
    await builder.testbed.availability.create(node)
  node
