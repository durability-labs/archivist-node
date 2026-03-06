## TOML Config Serialization Tests

import std/options
import pkg/toml_serialization
import pkg/confutils/defs
import pkg/libp2p
import pkg/ethers
import ../archivist/conf
import ../archivist/conf_serialization
import ../archivist/units
import ../archivist/nat
import ../archivist/utils/natutils

echo "=== Test 1: Simple types ==="
var config1 = default(NodeConf)
config1.dataDir = OutDir("/tmp/test")
config1.logLevel = "debug"
config1.numThreads = ThreadCount(4)
config1.storageQuota = GiBs(1)
config1.blockTtl = 3600.seconds
config1.maxPeers = 50

let toml1 = toToml(config1)
let decoded1 = Toml.decode(toml1, NodeConf)

assert string(decoded1.dataDir) == string(config1.dataDir)
assert decoded1.logLevel == config1.logLevel
assert decoded1.numThreads == config1.numThreads
assert decoded1.storageQuota == config1.storageQuota
assert decoded1.blockTtl == config1.blockTtl
assert decoded1.maxPeers == config1.maxPeers
echo "✓ Test 1 passed\n"

echo "=== Test 2: Network types ==="
var config2 = default(NodeConf)
config2.metricsAddress = parseIpAddress("192.168.1.100")
config2.metricsPort = Port(9090)
config2.discoveryPort = Port(8090)
config2.apiPort = Port(8080)

let maResult = MultiAddress.init("/ip4/127.0.0.1/tcp/0")
assert maResult.isOk
config2.listenAddrs = @[maResult.get()]

let toml2 = toToml(config2)
let decoded2 = Toml.decode(toml2, NodeConf)

assert decoded2.metricsAddress == config2.metricsAddress
assert decoded2.metricsPort == config2.metricsPort
assert decoded2.discoveryPort == config2.discoveryPort
assert decoded2.apiPort == config2.apiPort
assert decoded2.listenAddrs.len == config2.listenAddrs.len
assert decoded2.listenAddrs[0] == config2.listenAddrs[0]
echo "✓ Test 2 passed\n"

echo "=== Test 3: Enum types ==="
var config3 = default(NodeConf)
config3.logFormat = LogKind.Json
config3.repoKind = RepoKind.repoSQLite
config3.proverBackend = ProverBackendCmd.circomcompat
config3.curve = Curves.bn128

let toml3 = toToml(config3)
let decoded3 = Toml.decode(toml3, NodeConf)

assert decoded3.logFormat == config3.logFormat
assert decoded3.repoKind == config3.repoKind
assert decoded3.proverBackend == config3.proverBackend
assert decoded3.curve == config3.curve
echo "✓ Test 3 passed\n"

echo "=== Test 4: Option types ==="
var config4 = default(NodeConf)
config4.apiCorsAllowedOrigin = some("*")
config4.logFile = some("/tmp/archivist.log")
config4.ethPrivateKey = some("/path/to/private.key")
config4.validatorGroups = some(4)

let toml4 = toToml(config4)
let decoded4 = Toml.decode(toml4, NodeConf)

assert decoded4.apiCorsAllowedOrigin == config4.apiCorsAllowedOrigin
assert decoded4.logFile == config4.logFile
assert decoded4.ethPrivateKey == config4.ethPrivateKey
assert decoded4.validatorGroups == config4.validatorGroups
echo "✓ Test 4 passed\n"

echo "=== Test 5: Complex types ==="
var config5 = default(NodeConf)
config5.nat = NatConfig(hasExtIp: false, nat: NatStrategy.NatAny)
config5.bootstrapNodes = @[]

let toml5 = toToml(config5)
let decoded5 = Toml.decode(toml5, NodeConf)

assert decoded5.nat.hasExtIp == config5.nat.hasExtIp
assert decoded5.nat.nat == config5.nat.nat
assert decoded5.bootstrapNodes.len == config5.bootstrapNodes.len
echo "✓ Test 5 passed\n"

echo "=== Test 6: File path types ==="
var config6 = default(NodeConf)
config6.dataDir = OutDir("/tmp/archivist_data")
config6.circuitDir = OutDir("/tmp/circuits")
config6.circomR1cs = InputFile("/tmp/circuits/proof_main.r1cs")
config6.circomGraph = InputFile("/tmp/circuits/proof_main.bin")
config6.circomWasm = InputFile("/tmp/circuits/proof_main.wasm")
config6.circomZkey = InputFile("/tmp/circuits/proof_main.zkey")

let toml6 = toToml(config6)
let decoded6 = Toml.decode(toml6, NodeConf)

assert string(decoded6.dataDir) == string(config6.dataDir)
assert string(decoded6.circuitDir) == string(config6.circuitDir)
assert string(decoded6.circomR1cs) == string(config6.circomR1cs)
assert string(decoded6.circomGraph) == string(config6.circomGraph)
assert string(decoded6.circomWasm) == string(config6.circomWasm)
assert string(decoded6.circomZkey) == string(config6.circomZkey)
echo "✓ Test 6 passed\n"

echo "=== Test 7: Full config round-trip ==="
var config7 = default(NodeConf)
config7.dataDir = OutDir("/tmp/archivist_test")
config7.logLevel = "info"
config7.logFormat = LogKind.Colors
config7.metricsEnabled = true
config7.metricsAddress = parseIpAddress("127.0.0.1")
config7.metricsPort = Port(8008)
config7.listenAddrs = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").expect("valid")]
config7.nat = NatConfig(hasExtIp: false, nat: NatStrategy.NatAny)
config7.discoveryPort = Port(8090)
config7.netPrivKeyFile = "test_key"
config7.maxPeers = 160
config7.numThreads = ThreadCount(0)
config7.agentString = "Test Archivist Node"
config7.apiBindAddress = "127.0.0.1"
config7.apiPort = Port(8080)
config7.apiCorsAllowedOrigin = some("*")
config7.repoKind = RepoKind.repoFS
config7.storageQuota = GiBs(10)
config7.blockTtl = 7200.seconds
config7.blockMaintenanceInterval = 300.seconds
config7.blockMaintenanceNumberOfBlocks = 100
config7.cacheSize = MiBs(512)
config7.logFile = some("/tmp/archivist.log")
config7.persistence = false
config7.ethProvider = "ws://localhost:8545"
config7.validator = false
config7.validatorMaxSlots = 1000
config7.prover = false
config7.circuitDir = OutDir("/tmp/circuits")
config7.proverBackend = ProverBackendCmd.nimgroth16
config7.curve = Curves.bn128
config7.circomR1cs = InputFile("/tmp/circuits/proof_main.r1cs")
config7.circomGraph = InputFile("/tmp/circuits/proof_main.bin")
config7.circomWasm = InputFile("/tmp/circuits/proof_main.wasm")
config7.circomZkey = InputFile("/tmp/circuits/proof_main.zkey")
config7.numProofSamples = 10
config7.maxSlotDepth = 16
config7.maxDatasetDepth = 8
config7.maxBlockDepth = 12
config7.maxCellElms = 4096

let toml7 = toToml(config7)
let decoded7 = Toml.decode(toml7, NodeConf)

assert string(decoded7.dataDir) == string(config7.dataDir)
assert decoded7.logLevel == config7.logLevel
assert decoded7.logFormat == config7.logFormat
assert decoded7.metricsEnabled == config7.metricsEnabled
assert decoded7.metricsAddress == config7.metricsAddress
assert decoded7.metricsPort == config7.metricsPort
assert decoded7.maxPeers == config7.maxPeers
assert decoded7.numThreads == config7.numThreads
assert decoded7.agentString == config7.agentString
assert decoded7.repoKind == config7.repoKind
assert decoded7.storageQuota == config7.storageQuota
assert decoded7.validator == config7.validator
assert decoded7.prover == config7.prover
assert decoded7.proverBackend == config7.proverBackend
assert decoded7.curve == config7.curve
assert string(decoded7.circuitDir) == string(config7.circuitDir)
assert string(decoded7.circomR1cs) == string(config7.circomR1cs)
assert string(decoded7.circomGraph) == string(config7.circomGraph)
assert string(decoded7.circomWasm) == string(config7.circomWasm)
assert string(decoded7.circomZkey) == string(config7.circomZkey)
echo "✓ Test 7 passed\n"

echo "=== Test 8: Empty arrays and None options ==="
var config8 = default(NodeConf)
config8.listenAddrs = @[]
config8.bootstrapNodes = @[]
config8.apiCorsAllowedOrigin = none(string)
config8.logFile = none(string)
config8.ethPrivateKey = none(string)
config8.validatorGroups = none(int)

let toml8 = toToml(config8)
let decoded8 = Toml.decode(toml8, NodeConf)

assert decoded8.listenAddrs.len == 0
assert decoded8.bootstrapNodes.len == 0
assert decoded8.apiCorsAllowedOrigin.isNone
assert decoded8.logFile.isNone
assert decoded8.ethPrivateKey.isNone
assert decoded8.validatorGroups.isNone
echo "✓ Test 8 passed\n"

echo "\n=== All tests passed! ==="
