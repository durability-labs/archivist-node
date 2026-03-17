## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/os
import std/options
import std/strutils
import std/parseutils
import std/typetraits

import pkg/chronos
import pkg/chronicles/helpers
import pkg/chronicles/topics_registry
import pkg/confutils/defs
import pkg/confutils/std/net
import pkg/toml_serialization
import pkg/metrics
import pkg/metrics/chronos_httpserver
import pkg/stew/byteutils
import pkg/libp2p
import pkg/ethers
import pkg/questionable
import pkg/questionable/results

import ./archivisttypes
import ./discovery
import ./logutils
import ./stores
import ./marketplace
import ./units
import ./utils
import ./nat/config

when defaultChroniclesStream.outputs.type.arity == 3:
  import std/terminal

export units, net, archivisttypes, logutils, completeCmdArg, parseCmdArg, NatConfig
export ValidationGroups, MaxSlots

export
  DefaultQuotaBytes, DefaultOverlayTtl, DefaultBlockInterval,
  DefaultNumBlocksPerInterval, DefaultRequestCacheSize, DefaultMaxPriorityFeePerGas

type ThreadCount* = range[0 .. 256]

proc defaultDataDir*(): string =
  let dataDir =
    when defined(windows):
      "AppData" / "Roaming" / "Archivist"
    elif defined(macosx):
      "Library" / "Application Support" / "Archivist"
    else:
      ".cache" / "archivist"

  getHomeDir() / dataDir

const DefaultDataDir* = defaultDataDir()

proc toAbsolutePath*(path: string): string =
  try:
    absolutePath(path)
  except OSError, ValueError:
    path

type
  ProverBackendCmd* {.pure.} = enum
    nimgroth16
    circomcompat

  Curves* {.pure.} = enum
    bn128 = "bn128"

  LogKind* {.pure.} = enum
    Auto = "auto"
    Colors = "colors"
    NoColors = "nocolors"
    Json = "json"
    None = "none"

  RepoKind* = enum
    repoFS = "fs"
    repoSQLite = "sqlite"

  NodeConf* = object
    configFile* {.
      desc: "Loads the configuration from a TOML file",
      defaultValueDesc: "none",
      defaultValue: InputFile.none,
      name: "config-file"
    .}: Option[InputFile]

    logLevel* {.defaultValue: "info", desc: "Sets the log level", name: "log-level".}:
      string

    logFormat* {.
      desc:
        "Specifies what kind of logs should be written to stdout (auto, " &
        "colors, nocolors, json)",
      defaultValueDesc: "auto",
      defaultValue: LogKind.Auto,
      name: "log-format"
    .}: LogKind

    metricsEnabled* {.
      desc: "Enable the metrics server", defaultValue: false, name: "metrics"
    .}: bool

    metricsAddress* {.
      desc: "Listening address of the metrics server",
      defaultValue: defaultAddress(config),
      defaultValueDesc: "127.0.0.1",
      name: "metrics-address"
    .}: IpAddress

    metricsPort* {.
      desc: "Listening HTTP port of the metrics server",
      defaultValue: 8008,
      name: "metrics-port"
    .}: Port

    dataDir* {.
      desc: "The directory where the node will store configuration and data",
      defaultValue: defaultDataDir(),
      defaultValueDesc: "",
      abbr: "d",
      name: "data-dir"
    .}: OutDir

    listenAddrs* {.
      desc: "Multi Addresses to listen on",
      defaultValue:
        @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").expect("Should init multiaddress")],
      defaultValueDesc: "/ip4/0.0.0.0/tcp/0",
      abbr: "i",
      name: "listen-addrs"
    .}: seq[MultiAddress]

    nat* {.
      desc:
        "Specify method to use for determining public address. " &
        "Must be one of: any, none, upnp, pmp, extip:<IP>, pmp:<gateway>, any:<gateway>",
      defaultValue: defaultNatConfig(),
      defaultValueDesc: "any",
      name: "nat"
    .}: NatConfig

    discoveryPort* {.
      desc: "Discovery (UDP) port",
      defaultValue: 8090.Port,
      defaultValueDesc: "8090",
      abbr: "u",
      name: "disc-port"
    .}: Port

    netPrivKeyFile* {.
      desc: "Source of network (secp256k1) private key file path or name",
      defaultValue: "key",
      name: "net-privkey"
    .}: string

    bootstrapNodes* {.
      desc:
        "Specifies one or more bootstrap nodes to use when " &
        "connecting to the network",
      abbr: "b",
      name: "bootstrap-node"
    .}: seq[SignedPeerRecord]

    maxPeers* {.
      desc: "The maximum number of peers to connect to",
      defaultValue: 160,
      name: "max-peers"
    .}: int

    numThreads* {.
      desc:
        "Number of worker threads (\"0\" = use as many threads as there are CPU cores available)",
      defaultValueDesc: "0",
      defaultValue: ThreadCount(0),
      name: "num-threads"
    .}: ThreadCount

    agentString* {.
      defaultValue: "Archivist Node",
      desc: "Node agent string which is used as identifier in network",
      name: "agent-string"
    .}: string

    apiBindAddress* {.
      desc: "The REST API bind address", defaultValue: "127.0.0.1", name: "api-bindaddr"
    .}: string

    apiPort* {.
      desc: "The REST Api port",
      defaultValue: 8080.Port,
      defaultValueDesc: "8080",
      name: "api-port",
      abbr: "p"
    .}: Port

    apiCorsAllowedOrigin* {.
      desc:
        "The REST Api CORS allowed origin for downloading data. " &
        "'*' will allow all origins, '' will allow none.",
      defaultValue: string.none,
      defaultValueDesc: "Disallow all cross origin requests to download data",
      name: "api-cors-origin"
    .}: Option[string]

    repoKind* {.
      desc: "Backend for main repo store (fs, sqlite)",
      defaultValueDesc: "fs",
      defaultValue: repoFS,
      name: "repo-kind"
    .}: RepoKind

    fsDirectIO* {.
      desc:
        "Use O_DIRECT for filesystem writes (bypass page cache). " &
        "FS backend only. May cause EINVAL on some platforms.",
      defaultValue: false,
      defaultValueDesc: "false",
      name: "fs-direct-io"
    .}: bool

    fsFsyncFile* {.
      desc: "Fsync files after write in filesystem backend. " & "FS backend only.",
      defaultValue: true,
      defaultValueDesc: "true",
      name: "fs-fsync-file"
    .}: bool

    fsFsyncDir* {.
      desc:
        "Fsync parent directory after rename/delete in filesystem backend. " &
        "FS backend only.",
      defaultValue: true,
      defaultValueDesc: "true",
      name: "fs-fsync-dir"
    .}: bool

    storageQuota* {.
      desc: "The size of the total storage quota dedicated to the node",
      defaultValue: DefaultQuotaBytes,
      defaultValueDesc: $DefaultQuotaBytes,
      name: "storage-quota",
      abbr: "q"
    .}: NBytes

    overlayTtl* {.
      desc: "Default overlay timeout in seconds - 0 disables the ttl",
      defaultValue: DefaultOverlayTtl.seconds,
      defaultValueDesc: $DefaultOverlayTtl,
      name: "overlay-ttl",
      abbr: "t"
    .}: Duration

    overlayMaintenanceInterval* {.
      desc:
        "Time interval in seconds - determines frequency of block " &
        "maintenance cycle: how often blocks are checked " & "for expiration and cleanup",
      defaultValue: DefaultBlockInterval,
      defaultValueDesc: $DefaultBlockInterval,
      name: "block-mi"
    .}: Duration

    overlayMaintenanceNumberOfBlocks* {.
      desc: "Number of blocks to check every maintenance cycle",
      defaultValue: DefaultNumBlocksPerInterval,
      defaultValueDesc: $DefaultNumBlocksPerInterval,
      name: "block-mn"
    .}: int

    cacheSize* {.
      desc:
        "The size of the block cache, 0 disables the cache - " &
        "might help on slow hardrives",
      defaultValue: 0,
      defaultValueDesc: "0",
      name: "cache-size",
      abbr: "c"
    .}: NBytes

    logFile* {.
      desc: "Logs to file", defaultValue: string.none, name: "log-file", hidden
    .}: Option[string]

    persistence* {.
      desc: "Enables marketplace persistence. Requires 'eth-provider' option to be set.",
      defaultValue: false,
      name: "persistence"
    .}: bool

    ethProvider* {.
      desc: "The URL of the JSON-RPC API of the Ethereum node",
      defaultValue: "ws://localhost:8545",
      name: "eth-provider"
    .}: string

    ethPrivateKey* {.
      desc: "File containing Ethereum private key for storage contracts",
      defaultValue: string.none,
      defaultValueDesc: "",
      name: "eth-private-key"
    .}: Option[string]

    marketplaceAddress* {.
      desc: "Address of deployed Marketplace contract",
      defaultValue: EthAddress.none,
      defaultValueDesc: "",
      name: "marketplace-address"
    .}: Option[EthAddress]

    useSystemClock* {.
      desc: "Assume system clock is accurate enough for chain-related operations",
      defaultValue: false,
      name: "use-system-clock"
    .}: bool

    validator* {.
      desc: "Enables validator, requires an Ethereum node",
      defaultValue: false,
      name: "validator"
    .}: bool

    validatorMaxSlots* {.
      desc: "Maximum number of slots that the validator monitors",
      longDesc:
        "If set to 0, the validator will not limit " &
        "the maximum number of slots it monitors",
      defaultValue: 1000,
      name: "validator-max-slots"
    .}: MaxSlots

    validatorGroups* {.
      desc: "Slot validation groups",
      longDesc:
        "A number indicating total number of groups into " &
        "which the whole slot id space will be divided. " &
        "The value must be in the range [2, 65535]. " &
        "If not provided, the validator will observe " &
        "the whole slot id space and the value of " &
        "the --validator-group-index parameter will be ignored. " &
        "Powers of twos are advised for even distribution",
      defaultValue: int.none,
      name: "validator-groups"
    .}: Option[int]

    validatorGroupIndex* {.
      desc: "Slot validation group index",
      longDesc:
        "The value provided must be in the range " &
        "[0, validatorGroups). Ignored when --validator-groups " &
        "is not provided. Only slot ids satisfying condition " &
        "[(slotId mod validationGroups) == groupIndex] will be " &
        "observed by the validator",
      defaultValue: 0,
      name: "validator-group-index"
    .}: uint16

    marketplaceRequestCacheSize* {.
      desc:
        "Maximum number of StorageRequests kept in memory." &
        "Reduces fetching of StorageRequest data from the contract.",
      defaultValue: DefaultRequestCacheSize,
      defaultValueDesc: $DefaultRequestCacheSize,
      name: "request-cache-size",
      hidden
    .}: uint16

    maxPriorityFeePerGas* {.
      desc:
        "Sets the default maximum priority fee per gas for Ethereum EIP-1559 transactions, in wei, when not provided by the network.",
      defaultValue: DefaultMaxPriorityFeePerGas,
      defaultValueDesc: $DefaultMaxPriorityFeePerGas,
      name: "max-priority-fee-per-gas",
      hidden
    .}: uint64

    prover* {.
      desc:
        "Enables zkProver system, required to generate storage proofs. Requires 'persistence' to be enabled.",
      defaultValue: false,
      name: "prover"
    .}: bool

    circuitDir* {.
      desc: "Directory where the node will store proof circuit data",
      defaultValue: OutDir($config.dataDir / "circuits"),
      defaultValueDesc: "<data-dir>/circuits",
      abbr: "cd",
      name: "circuit-dir"
    .}: OutDir

    proverBackend* {.
      desc:
        "The backend to use for the prover. " &
        "Must be one of: nimgroth16, circomcompat",
      defaultValue: ProverBackendCmd.nimgroth16,
      defaultValueDesc: "nimgroth16",
      name: "prover-backend"
    .}: ProverBackendCmd

    curve* {.
      desc: "The curve to use for the storage circuit",
      defaultValue: Curves.bn128,
      defaultValueDesc: $Curves.bn128,
      name: "curve"
    .}: Curves

    circomR1cs* {.
      desc: "The r1cs file for the storage circuit",
      defaultValue: config.circuitDirPath / "proof_main.r1cs",
      defaultValueDesc: "<circuit-dir>/proof_main.r1cs",
      name: "circom-r1cs"
    .}: InputFile

    circomGraph* {.
      desc: "The graph file for the storage circuit (only used with nimgroth16 backend)",
      defaultValue: config.circuitDirPath / "proof_main.bin",
      defaultValueDesc: "<circuit-dir>/proof_main.bin",
      name: "circom-graph"
    .}: InputFile

    circomWasm* {.
      desc:
        "The wasm file for the storage circuit (only used with circomcompat backend)",
      defaultValue: config.circuitDirPath / "proof_main.wasm",
      defaultValueDesc: "<circuit-dir>/proof_main.wasm",
      name: "circom-wasm"
    .}: InputFile

    circomZkey* {.
      desc: "The zkey file for the storage circuit",
      defaultValue: config.circuitDirPath / "proof_main.zkey",
      defaultValueDesc: "<circuit-dir>/proof_main.zkey",
      name: "circom-zkey"
    .}: InputFile

    circomNoZkey* {.
      desc: "Ignore the zkey file - use only for testing!",
      defaultValue: false,
      name: "circom-no-zkey",
      hidden
    .}: bool

    numProofSamples* {.
      desc: "Number of samples to prove",
      defaultValue: DefaultSamplesNum,
      defaultValueDesc: $DefaultSamplesNum,
      name: "proof-samples"
    .}: int

    maxSlotDepth* {.
      desc: "The maximum depth of the slot tree",
      defaultValue: DefaultMaxSlotDepth,
      defaultValueDesc: $DefaultMaxSlotDepth,
      name: "max-slot-depth"
    .}: int

    maxDatasetDepth* {.
      desc: "The maximum depth of the dataset tree",
      defaultValue: DefaultMaxDatasetDepth,
      defaultValueDesc: $DefaultMaxDatasetDepth,
      name: "max-dataset-depth"
    .}: int

    maxBlockDepth* {.
      desc: "The maximum depth of the network block merkle tree",
      defaultValue: DefaultBlockDepth,
      defaultValueDesc: $DefaultBlockDepth,
      name: "max-block-depth"
    .}: int

    maxCellElms* {.
      desc: "The maximum number of elements in a cell",
      defaultValue: DefaultCellElms,
      defaultValueDesc: $DefaultCellElms,
      name: "max-cell-elements"
    .}: int

  EthAddress* = ethers.Address

logutils.formatIt(LogFormat.textLines, EthAddress):
  it.short0xHexLog
logutils.formatIt(LogFormat.json, EthAddress):
  %it

func defaultAddress*(conf: NodeConf): IpAddress =
  result = static parseIpAddress("127.0.0.1")

func defaultNatConfig*(): NatConfig =
  result = NatConfig.anyStrategy()

proc circuitDirPath*(self: NodeConf): string =
  ## Returns the circuit directory as an absolute path
  toAbsolutePath($self.circuitDir)

proc getNodeVersion(): string =
  let tag = strip(staticExec("git tag"))
  if tag.isEmptyOrWhitespace:
    return "untagged build"
  return tag

proc getNodeRevision(): string =
  # using a slice in a static context breaks nimsuggest for some reason
  var res = strip(staticExec("git rev-parse --short HEAD"))
  return res

proc getContractsRevision(): string =
  let res = strip(staticExec("git rev-parse --short HEAD:vendor/archivist-contracts"))
  return res

proc getNimBanner(): string =
  staticExec("nim --version | grep Version")

const
  nodeVersion* = getNodeVersion()
  nodeRevision* = getNodeRevision()
  contractsRevision* = getContractsRevision()
  nimBanner* = getNimBanner()

  nodeFullVersion* =
    "Archivist node version:  " & nodeVersion & "\p" & "Archivist node revision: " &
    nodeRevision & "\p" & "Archivist contracts revision: " & contractsRevision & "\p" &
    nimBanner

proc parseCmdArg*(
    T: typedesc[MultiAddress], input: string
): MultiAddress {.raises: [ValueError].} =
  var ma: MultiAddress
  try:
    let res = MultiAddress.init(input)
    if res.isOk:
      ma = res.get()
    else:
      warn "Invalid MultiAddress", input = input, error = res.error()
      quit QuitFailure
  except LPError as exc:
    warn "Invalid MultiAddress uri", uri = input, error = exc.msg
    quit QuitFailure
  ma

proc parseCmdArg*(T: type ThreadCount, input: string): T {.raises: [ValueError].} =
  let count = parseInt(input)
  if count != 0 and count < 2:
    warn "Invalid number of threads", input = input
    quit QuitFailure
  ThreadCount(count)

proc parseCmdArg*(T: type SignedPeerRecord, uri: string): T =
  var res: SignedPeerRecord
  try:
    if not res.fromURI(uri):
      warn "Invalid SignedPeerRecord uri", uri = uri
      quit QuitFailure
  except LPError as exc:
    warn "Invalid SignedPeerRecord uri", uri = uri, error = exc.msg
    quit QuitFailure
  except CatchableError as exc:
    warn "Invalid SignedPeerRecord uri", uri = uri, error = exc.msg
    quit QuitFailure
  res

func parseCmdArg*(T: type NatConfig, nat: string): T {.raises: [ValueError].} =
  let parts = nat.split(":", 1)
  let strategy = parts[0]
  var address: ?IpAddress
  if argument =? parts.?[1]:
    without parsed =? parseIpAddress(argument).catch:
      raise newException(ValueError, "Not a valid IP address: " & argument)
    address = some parsed
  case strategy
  of "any":
    NatConfig.anyStrategy(gateway = address)
  of "none":
    NatConfig.noNat()
  of "upnp":
    NatConfig.upnp()
  of "pmp":
    NatConfig.pmp(gateway = address)
  of "extip":
    without ip =? address:
      raise newException(ValueError, "Missing external IP address")
    NatConfig.externalIp(ip)
  else:
    raise newException(ValueError, "Not a valid NAT option: " & nat)

proc completeCmdArg*(T: type NatConfig, val: string): seq[string] =
  return @[]

proc parseCmdArg*(T: type EthAddress, address: string): T =
  EthAddress.init($address).get()

proc parseCmdArg*(T: type NBytes, val: string): T =
  var num = 0'i64
  let count = parseSize(val, num, alwaysBin = true)
  if count == 0:
    warn "Invalid number of bytes", nbytes = val
    quit QuitFailure
  NBytes(num)

proc parseCmdArg*(T: type Duration, val: string): T =
  var dur: Duration
  let count = parseDuration(val, dur)
  if count == 0:
    warn "Cannot parse duration", dur = dur
    quit QuitFailure
  dur

proc readValue*(
    r: var TomlReader, val: var EthAddress
) {.raises: [SerializationError, IOError].} =
  val = EthAddress.init(r.readValue(string)).get()

proc readValue*(r: var TomlReader, val: var SignedPeerRecord) =
  without uri =? r.readValue(string).catch, err:
    error "invalid SignedPeerRecord configuration value", error = err.msg
    quit QuitFailure

  try:
    val = SignedPeerRecord.parseCmdArg(uri)
  except LPError as err:
    warn "Invalid SignedPeerRecord uri", uri = uri, error = err.msg
    quit QuitFailure

proc readValue*(r: var TomlReader, val: var MultiAddress) =
  without input =? r.readValue(string).catch, err:
    error "invalid MultiAddress configuration value", error = err.msg
    quit QuitFailure

  let res = MultiAddress.init(input)
  if res.isOk:
    val = res.get()
  else:
    warn "Invalid MultiAddress", input = input, error = res.error()
    quit QuitFailure

proc readValue*(
    r: var TomlReader, val: var NBytes
) {.raises: [SerializationError, IOError].} =
  var value = 0'i64
  var str = r.readValue(string)
  let count = parseSize(str, value, alwaysBin = true)
  if count == 0:
    error "invalid number of bytes for configuration value", value = str
    quit QuitFailure
  val = NBytes(value)

proc readValue*(
    r: var TomlReader, val: var ThreadCount
) {.raises: [SerializationError, IOError].} =
  var str = r.readValue(string)
  try:
    val = parseCmdArg(ThreadCount, str)
  except CatchableError as err:
    raise newException(SerializationError, err.msg)

proc readValue*(
    r: var TomlReader, val: var Duration
) {.raises: [SerializationError, IOError].} =
  var str = r.readValue(string)
  var dur: Duration
  let count = parseDuration(str, dur)
  if count == 0:
    error "Invalid duration parse", value = str
    quit QuitFailure
  val = dur

proc readValue*(
    r: var TomlReader, val: var NatConfig
) {.raises: [SerializationError].} =
  val =
    try:
      parseCmdArg(NatConfig, r.readValue(string))
    except CatchableError as err:
      raise newException(SerializationError, err.msg)

# no idea why confutils needs this:
proc completeCmdArg*(T: type EthAddress, val: string): seq[string] =
  discard

proc completeCmdArg*(T: type NBytes, val: string): seq[string] =
  discard

proc completeCmdArg*(T: type Duration, val: string): seq[string] =
  discard

proc completeCmdArg*(T: type ThreadCount, val: string): seq[string] =
  discard

# silly chronicles, colors is a compile-time property
proc stripAnsi*(v: string): string =
  var
    res = newStringOfCap(v.len)
    i: int

  while i < v.len:
    let c = v[i]
    if c == '\x1b':
      var
        x = i + 1
        found = false

      while x < v.len: # look for [..m
        let c2 = v[x]
        if x == i + 1:
          if c2 != '[':
            break
        else:
          if c2 in {'0' .. '9'} + {';'}:
            discard # keep looking
          elif c2 == 'm':
            i = x + 1
            found = true
            break
          else:
            break
        inc x

      if found: # skip adding c
        continue
    res.add c
    inc i

  res

proc updateLogLevel*(logLevel: string) {.raises: [ValueError].} =
  # Updates log levels (without clearing old ones)
  let directives = logLevel.split(";")
  try:
    setLogLevel(parseEnum[LogLevel](directives[0].toUpperAscii))
  except ValueError:
    raise (ref ValueError)(
      msg:
        "Please specify one of: trace, debug, " & "info, notice, warn, error or fatal"
    )

  if directives.len > 1:
    for topicName, settings in parseTopicDirectives(directives[1 ..^ 1]):
      if not setTopicState(topicName, settings.state, settings.logLevel):
        warn "Unrecognized logging topic", topic = topicName

proc setupLogging*(conf: NodeConf) =
  when defaultChroniclesStream.outputs.type.arity != 3:
    warn "Logging configuration options not enabled in the current build"
  else:
    var logFile: ?IoHandle
    proc noOutput(logLevel: LogLevel, msg: LogOutputStr) =
      discard

    proc writeAndFlush(f: File, msg: LogOutputStr) =
      try:
        f.write(msg)
        f.flushFile()
      except IOError as err:
        logLoggingFailure(cstring(msg), err)

    proc stdoutFlush(logLevel: LogLevel, msg: LogOutputStr) =
      writeAndFlush(stdout, msg)

    proc noColorsFlush(logLevel: LogLevel, msg: LogOutputStr) =
      writeAndFlush(stdout, stripAnsi(msg))

    proc fileFlush(logLevel: LogLevel, msg: LogOutputStr) =
      if file =? logFile:
        if error =? file.writeFile(stripAnsi(msg).toBytes).errorOption:
          error "failed to write to log file", errorCode = $error

    defaultChroniclesStream.outputs[2].writer = noOutput
    if logFilePath =? conf.logFile and logFilePath.len > 0:
      let logFileHandle =
        openFile(logFilePath, {OpenFlags.Write, OpenFlags.Create, OpenFlags.Truncate})
      if logFileHandle.isErr:
        error "failed to open log file",
          path = logFilePath, errorCode = $logFileHandle.error
      else:
        logFile = logFileHandle.option
        defaultChroniclesStream.outputs[2].writer = fileFlush

    defaultChroniclesStream.outputs[1].writer = noOutput

    let writer =
      case conf.logFormat
      of LogKind.Auto:
        if isatty(stdout): stdoutFlush else: noColorsFlush
      of LogKind.Colors:
        stdoutFlush
      of LogKind.NoColors:
        noColorsFlush
      of LogKind.Json:
        defaultChroniclesStream.outputs[1].writer = stdoutFlush
        noOutput
      of LogKind.None:
        noOutput

    when defined(archivist_system_testing_options):
      var counter = 0.uint64
      proc numberedWriter(logLevel: LogLevel, msg: LogOutputStr) =
        inc(counter)
        var withoutNewLine = $msg
        withoutNewLine.removeSuffix
        writer(logLevel, withoutNewLine & " count=" & $counter & "\n")

      defaultChroniclesStream.outputs[0].writer = numberedWriter
    else:
      defaultChroniclesStream.outputs[0].writer = writer

  try:
    updateLogLevel(conf.logLevel)
  except ValueError as err:
    try:
      stderr.write "Invalid value for --log-level. " & err.msg & "\n"
    except IOError:
      echo "Invalid value for --log-level. " & err.msg
    quit QuitFailure

proc setupMetrics*(config: NodeConf) =
  if config.metricsEnabled:
    let metricsAddress = config.metricsAddress
    notice "Starting metrics HTTP server",
      url = "http://" & $metricsAddress & ":" & $config.metricsPort & "/metrics"
    try:
      startMetricsHttpServer($metricsAddress, config.metricsPort)
    except CatchableError as exc:
      raiseAssert exc.msg
    except Exception as exc:
      raiseAssert exc.msg # TODO fix metrics
