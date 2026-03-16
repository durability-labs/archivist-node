import std/os
import std/net
import std/tempfiles
import std/strutils
import pkg/chronos
import pkg/questionable
import pkg/stew/io2
import ../network/node
import ../network/hardhat
import ../helpers/project
import ../helpers/ports
import ../testbed
import ./api
import ./availability

when defined(windows):
  import pkg/stew/windows/acl

type NodeBuilder = ref object
  testbed: Testbed
  dataDir: ?string
  apiBindAddress: ?IpAddress
  apiPort: ?Port
  discoveryPort: ?Port
  bootstrapNodes: ?seq[string]
  logToFile: bool
  logTopics: seq[string]
  persistence: bool
  ethPrivateKey: ? ?string
  marketplaceAddress: ?string
  validator: bool
  validatorGroups: ?int
  validatorGroupIndex: ?int
  prover: bool
  proverBackend: ?string
  circomR1cs: ? ?string
  circomWasm: ? ?string
  circomZkey: ? ?string
  circomGraph: ? ?string
  failProofs: ?int
  storageQuota: ?int
  overlayTtl: ?int
  overlayMaintenanceInterval: ?int
  waitForOutput: ?string
  setInitialAvailability: bool

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

func log*(builder: NodeBuilder, topics: varargs[string]): NodeBuilder =
  builder.logToFile = true
  builder.logTopics &= topics
  builder

proc logFile(builder: NodeBuilder): ?string =
  if builder.logToFile or getEnv("CI") == "true":
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

func marketplaceAddress*(builder: NodeBuilder, address: string): NodeBuilder =
  builder.marketplaceAddress = some address
  builder

func validator*(builder: NodeBuilder): NodeBuilder =
  builder.persistence = true
  builder.validator = true
  builder.logTopics &= "validator"
  builder

func validator*(builder: NodeBuilder, groups, index: int): NodeBuilder =
  builder.validatorGroups = some groups
  builder.validatorGroupIndex = some index
  builder.validator()

func prover*(builder: NodeBuilder): NodeBuilder =
  builder.prover = true
  builder

func circomR1cs*(builder: NodeBuilder, filename: string): NodeBuilder =
  builder.circomR1cs = some some filename
  builder

func noCircomR1cs*(builder: NodeBuilder): NodeBuilder =
  builder.circomR1cs = some none string
  builder

func circomWasm*(builder: NodeBuilder, filename: string): NodeBuilder =
  builder.circomWasm = some some filename
  builder

func noCircomWasm*(builder: NodeBuilder): NodeBuilder =
  builder.circomWasm = some none string
  builder

func circomZkey*(builder: NodeBuilder, filename: string): NodeBuilder =
  builder.circomZkey = some some filename
  builder

func noCircomZkey*(builder: NodeBuilder): NodeBuilder =
  builder.circomZkey = some none string
  builder

func circomGraph*(builder: NodeBuilder, filename: string): NodeBuilder =
  builder.circomGraph = some some filename
  builder

func noCircomGraph*(builder: NodeBuilder): NodeBuilder =
  builder.circomGraph = some none string
  builder

func provider*(builder: NodeBuilder): NodeBuilder =
  builder.persistence = true
  builder.prover = true
  builder.setInitialAvailability = true
  builder

func proverBackend*(builder: NodeBuilder, backend: string): NodeBuilder =
  builder.proverBackend = some backend
  builder

func waitForOutput*(builder: NodeBuilder, output: string): NodeBuilder =
  builder.waitForOutput = some output
  builder

func availability*(builder: NodeBuilder, setInitialAvailability: bool): NodeBuilder =
  builder.setInitialAvailability = setInitialAvailability
  builder

func failProofs*(builder: NodeBuilder, every: int): NodeBuilder =
  builder.failProofs = some every
  builder

func storageQuota*(builder: NodeBuilder, quota: int): NodeBuilder =
  builder.storageQuota = some quota
  builder

func overlayTtl*(builder: NodeBuilder, ttl: int): NodeBuilder =
  builder.overlayTtl = some ttl
  builder

func overlayMaintenanceInterval*(builder: NodeBuilder, interval: int): NodeBuilder =
  builder.overlayMaintenanceInterval = some interval
  builder

proc dataDirResolved(builder: NodeBuilder): string =
  builder.dataDir |? createTempDir("archivist-", "-testbed")

func apiBindAddressResolved(builder: NodeBuilder): IpAddress =
  builder.apiBindAddress |? static parseIpAddress("0.0.0.0")

proc apiPortResolved(builder: NodeBuilder): Future[Port] {.async.} =
  let address = builder.apiBindAddressResolved()
  builder.apiPort |? await findFreePort(address, Port(8080), Tcp)

proc discoveryPortResolved(builder: NodeBuilder): Future[Port] {.async.} =
  const address = parseIpAddress("0.0.0.0")
  builder.discoveryPort |? await findFreePort(address, Port(8090), Udp)

proc bootstrapNodesResolved(builder: NodeBuilder): Future[seq[string]] {.async.} =
  if nodes =? builder.bootstrapNodes:
    return nodes
  if firstNode =? builder.testbed.nodeInstances .? [0]:
    if spr =? await builder.testbed.api(firstNode).getSpr():
      return @[spr]

proc ethPrivateKeyResolved(builder: NodeBuilder): ?string =
  if ethPrivateKey =? builder.ethPrivateKey:
    return ethPrivateKey
  if builder.persistence:
    if hardhat =? builder.testbed.hardhatInstance:
      let ethPrivateKey = hardhat.accounts.pop().privateKeyFile
      when defined(windows):
        setCurrentUserOnlyAccess(ethPrivateKey).tryGet()
      else:
        setPermissions(ethPrivateKey, 0o600).tryGet()
      return some ethPrivateKey
  none string

const circuitsDir = hardhatDir / "verifier" / "networks" / "hardhat"

func circomR1csResolved(builder: NodeBuilder): ?string =
  if circomR1cs =? builder.circomR1cs:
    return circomR1cs
  if builder.prover:
    return some circuitsDir / "proof_main.r1cs"

func circomWasmResolved(builder: NodeBuilder): ?string =
  if circomWasm =? builder.circomWasm:
    return circomWasm
  if builder.prover:
    return some circuitsDir / "proof_main.wasm"

func circomZkeyResolved(builder: NodeBuilder): ?string =
  if circomZkey =? builder.circomZkey:
    return circomZkey
  if builder.prover:
    return some circuitsDir / "proof_main.zkey"

func circomGraphResolved(builder: NodeBuilder): ?string =
  if circomGraph =? builder.circomGraph:
    return circomGraph
  if builder.prover:
    return some circuitsDir / "proof_main.bin"

proc start*(builder: NodeBuilder): Future[Node] {.async.} =
  var arguments: seq[string]
  arguments.add("--disc-port=" & $(await builder.discoveryPortResolved))
  for bootstrapNode in await builder.bootstrapNodesResolved:
    arguments.add("--bootstrap-node=" & bootstrapNode)
  if builder.logTopics.len > 0:
    arguments.add("--log-level=INFO;TRACE:" & builder.logTopics.join(","))
  if builder.persistence:
    arguments.add("--persistence")
    arguments.add("--eth-provider=" & builder.testbed.hardhatInstance.jsonRpcUrl)
  if ethPrivateKey =? builder.ethPrivateKeyResolved:
    arguments.add("--eth-private-key=" & ethPrivateKey)
  if marketplaceAddress =? builder.marketplaceAddress:
    arguments.add("--marketplace-address=" & marketplaceAddress)
  if builder.validator:
    arguments.add("--validator")
  if groups =? builder.validatorGroups:
    arguments.add("--validator-groups=" & $groups)
  if index =? builder.validatorGroupIndex:
    arguments.add("--validator-group-index=" & $index)
  if builder.prover:
    arguments.add("--prover")
  if backend =? builder.proverBackend:
    arguments.add("--prover-backend=" & backend)
  if circomR1cs =? builder.circomR1csResolved:
    arguments.add("--circom-r1cs=" & circomR1cs)
  if circomWasm =? builder.circomWasmResolved:
    arguments.add("--circom-wasm=" & circomWasm)
  if circomZkey =? builder.circomZkeyResolved:
    arguments.add("--circom-zkey=" & circomZkey)
  if circomGraph =? builder.circomGraphResolved:
    arguments.add("--circom-graph=" & circomGraph)
  if quota =? builder.storageQuota:
    arguments.add("--storage-quota=" & $quota)
  if overlayTtl =? builder.overlayTtl:
    arguments.add("--overlay-ttl=" & $overlayTtl)
  if overlayMaintenanceInterval =? builder.overlayMaintenanceInterval:
    arguments.add("--block-mi=" & $overlayMaintenanceInterval)
  let dataDir = builder.dataDirResolved
  let address = builder.apiBindAddressResolved
  let port = await builder.apiPortResolved
  let node = await Node.start(
    arguments,
    dataDir,
    address,
    port,
    logFile = builder.logFile,
    waitForOutput = some builder.waitForOutput |? "REST service started",
  )
  builder.testbed.nodeInstances.add(node)
  if builder.setInitialAvailability:
    await builder.testbed.availability.update(node)
  if failProofs =? builder.failProofs:
    await builder.testbed.api(node).setSimulateProofFailures(failProofs)
  node
