import std/os
import std/net
import std/tempfiles
import pkg/chronos
import pkg/questionable
import ../network/node
import ../network/hardhat
import ../network/hardhat/root
import ../helpers/project
import ../helpers/ports
import ../testbed
import ./api
import ./availability

type
  NodeBuilder = ref object
    testbed: Testbed
    dataDir: ?string
    apiBindAddress: ?IpAddress
    apiPort: ?Port
    discoveryPort: ?Port
    bootstrapNodes: ?seq[string]
    logToFile: bool
    persistence: bool = true
    ethPrivateKey: ? ? string
    validator: bool
    prover: bool
    circomR1cs: ?string
    circomWasm: ?string
    circomZkey: ?string
    failProofs: ?int
    createInitialAvailability: bool

func node*(testbed: Testbed): NodeBuilder =
  NodeBuilder(testbed: testbed)

func dataDir*(builder: NodeBuilder, dir: string): NodeBuilder =
  builder.dataDir = some dir
  builder

func apiBindAddress*(builder: NodeBuilder, address: IpAddress): NodeBuilder =
  builder.apiBindAddress = some address
  builder

func apiPort*(builder: NodeBuilder, port: Port): NodeBuilder =
  builder.apiPort = some port
  builder

func discoveryPort*(builder: NodeBuilder, port: Port): NodeBuilder =
  builder.discoveryPort = some port
  builder

func bootstrapNodes*(builder: NodeBuilder, sprs: seq[string]): NodeBuilder =
  builder.bootstrapNodes = some sprs
  builder

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

func validator*(builder: NodeBuilder): NodeBuilder =
  builder.validator = true
  builder

func prover*(builder: NodeBuilder): NodeBuilder =
  builder.prover = true
  builder

func provider*(builder: NodeBuilder): NodeBuilder =
  builder.persistence = true
  builder.prover = true
  builder.createInitialAvailability = true
  builder

func availability*(
  builder: NodeBuilder,
  createInitialAvailability: bool
): NodeBuilder =
  builder.createInitialAvailability = createInitialAvailability
  builder

func failProofs*(builder: NodeBuilder, every: int): NodeBuilder =
  builder.failProofs = some every
  builder

proc dataDirResolved(builder: NodeBuilder): string =
  builder.dataDir |? createTempDir("archivist-", "-testbed")

func apiBindAddressResolved(builder: NodeBuilder): IpAddress =
  builder.apiBindAddress |? static parseIpAddress("127.0.0.1")

proc apiPortResolved(builder: NodeBuilder): Future[Port] {.async.} =
  let address = builder.apiBindAddressResolved()
  builder.apiPort |? await findFreePort(address, Port(8080), Tcp)

proc discoveryPortResolved(builder: NodeBuilder): Future[Port] {.async.} =
  const address = parseIpAddress("127.0.0.1")
  builder.discoveryPort |? await findFreePort(address, Port(8090), Udp)

proc bootstrapNodesResolved(builder: NodeBuilder): Future[seq[string]] {.async.} =
  if nodes =? builder.bootstrapNodes:
    return nodes
  if firstNode =? builder.testbed.nodeInstances.?[0]:
    if spr =? await builder.testbed.api(firstNode).getSpr():
      return @[spr]

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
  arguments.add("--disc-port=" & $(await builder.discoveryPortResolved))
  for bootstrapNode in await builder.bootstrapNodesResolved:
    arguments.add("--bootstrap-node=" & bootstrapNode)
  if logFile =? builder.logFile:
    arguments.add("--log-file=" & logFile)
  if builder.persistence:
    arguments.add("persistence")
  if ethPrivateKey =? builder.ethPrivateKeyResolved:
    arguments.add("--eth-private-key=" & ethPrivateKey)
  if builder.validator:
    arguments.add("--validator")
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
  let dataDir = builder.dataDirResolved
  let address = builder.apiBindAddressResolved
  let port = await builder.apiPortResolved
  let node = await Node.start(arguments, dataDir, address, port).waitForRestApi()
  builder.testbed.nodeInstances.add(node)
  if builder.createInitialAvailability:
    await builder.testbed.availability.create(node)
  node
