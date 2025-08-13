import std/options
import std/os
import std/sequtils
import std/strutils
import std/sugar
import std/tables
from pkg/chronicles import LogLevel
import pkg/archivist/conf
import pkg/archivist/units
import pkg/confutils
import pkg/confutils/defs
import libp2p except setup
import pkg/questionable
import ./clioption

export clioption
export confutils

type
  ArchivistConfigs* = object
    configs*: seq[ArchivistConfig]

  ArchivistConfig* = object
    cliOptions: Table[StartUpCmd, Table[string, CliOption]]
    cliPersistenceOptions: Table[PersistenceCmd, Table[string, CliOption]]
    debugEnabled*: bool

  ArchivistConfigError* = object of CatchableError

proc cliArgs*(
  config: ArchivistConfig
): seq[string] {.gcsafe, raises: [ArchivistConfigError].}

proc raiseConfigError(msg: string) {.raises: [ArchivistConfigError].} =
  raise newException(ArchivistConfigError, msg)

template convertError(body) =
  try:
    body
  except CatchableError as e:
    raiseConfigError e.msg

proc init*(_: type ArchivistConfigs, nodes = 1): ArchivistConfigs {.raises: [].} =
  ArchivistConfigs(configs: newSeq[ArchivistConfig](nodes))

func nodes*(self: ArchivistConfigs): int =
  self.configs.len

proc checkBounds(self: ArchivistConfigs, idx: int) {.raises: [ArchivistConfigError].} =
  if idx notin 0 ..< self.configs.len:
    raiseConfigError "index must be in bounds of the number of nodes"

proc buildConfig(
    config: ArchivistConfig, msg: string
): NodeConf {.raises: [ArchivistConfigError].} =
  proc postFix(msg: string): string =
    if msg.len > 0:
      ": " & msg
    else:
      ""

  try:
    return NodeConf.load(cmdLine = config.cliArgs, quitOnFailure = false)
  except ConfigurationError as e:
    raiseConfigError msg & e.msg.postFix
  except Exception as e:
    ## TODO: remove once proper exception handling added to nim-confutils
    raiseConfigError msg & e.msg.postFix

proc addCliOption*(
    config: var ArchivistConfig, group = PersistenceCmd.noCmd, cliOption: CliOption
) {.raises: [ArchivistConfigError].} =
  var options = config.cliPersistenceOptions.getOrDefault(group)
  options[cliOption.key] = cliOption # overwrite if already exists
  config.cliPersistenceOptions[group] = options
  discard config.buildConfig("Invalid cli arg " & $cliOption)

proc addCliOption*(
    config: var ArchivistConfig, group = PersistenceCmd.noCmd, key: string, value = ""
) {.raises: [ArchivistConfigError].} =
  config.addCliOption(group, CliOption(key: key, value: value))

proc addCliOption*(
    config: var ArchivistConfig, group = StartUpCmd.noCmd, cliOption: CliOption
) {.raises: [ArchivistConfigError].} =
  var options = config.cliOptions.getOrDefault(group)
  options[cliOption.key] = cliOption # overwrite if already exists
  config.cliOptions[group] = options
  discard config.buildConfig("Invalid cli arg " & $cliOption)

proc addCliOption*(
    config: var ArchivistConfig, group = StartUpCmd.noCmd, key: string, value = ""
) {.raises: [ArchivistConfigError].} =
  config.addCliOption(group, CliOption(key: key, value: value))

proc addCliOption*(
    config: var ArchivistConfig, cliOption: CliOption
) {.raises: [ArchivistConfigError].} =
  config.addCliOption(StartUpCmd.noCmd, cliOption)

proc addCliOption*(
    config: var ArchivistConfig, key: string, value = ""
) {.raises: [ArchivistConfigError].} =
  config.addCliOption(StartUpCmd.noCmd, CliOption(key: key, value: value))

proc cliArgs*(
    config: ArchivistConfig
): seq[string] {.gcsafe, raises: [ArchivistConfigError].} =
  ## converts ArchivistConfig cli options and command groups in a sequence of args
  ## and filters out cli options by node index if provided in the CliOption
  var args: seq[string] = @[]

  convertError:
    for cmd in StartUpCmd:
      if config.cliOptions.hasKey(cmd):
        if cmd != StartUpCmd.noCmd:
          args.add $cmd
        var opts = config.cliOptions[cmd].values.toSeq
        args = args.concat(opts.map(o => $o))

    for cmd in PersistenceCmd:
      if config.cliPersistenceOptions.hasKey(cmd):
        if cmd != PersistenceCmd.noCmd:
          args.add $cmd
        var opts = config.cliPersistenceOptions[cmd].values.toSeq
        args = args.concat(opts.map(o => $o))

    return args

proc logFile*(config: ArchivistConfig): ?string {.raises: [ArchivistConfigError].} =
  let built = config.buildConfig("Invalid node config cli params")
  built.logFile

proc logLevel*(config: ArchivistConfig): LogLevel {.raises: [ArchivistConfigError].} =
  convertError:
    let built = config.buildConfig("Invalid node config cli params")
    return parseEnum[LogLevel](built.logLevel.toUpperAscii)

proc debug*(
    self: ArchivistConfigs, idx: int, enabled = true
): ArchivistConfigs {.raises: [ArchivistConfigError].} =
  ## output log in stdout for a specific node in the group

  self.checkBounds idx

  var startConfig = self
  startConfig.configs[idx].debugEnabled = enabled
  return startConfig

proc debug*(self: ArchivistConfigs, enabled = true): ArchivistConfigs {.raises: [].} =
  ## output log in stdout for all nodes in group
  var startConfig = self
  for config in startConfig.configs.mitems:
    config.debugEnabled = enabled
  return startConfig

proc withLogFile*(
    self: ArchivistConfigs, idx: int
): ArchivistConfigs {.raises: [ArchivistConfigError].} =
  self.checkBounds idx

  var startConfig = self
  startConfig.configs[idx].addCliOption("--log-file", "<updated_in_test>")
  return startConfig

proc withLogFile*(
    self: ArchivistConfigs
): ArchivistConfigs {.raises: [ArchivistConfigError].} =
  ## typically called from test, sets config such that a log file should be
  ## created
  var startConfig = self
  for config in startConfig.configs.mitems:
    config.addCliOption("--log-file", "<updated_in_test>")
  return startConfig

proc withLogFile*(
    self: var ArchivistConfig, logFile: string
) {.raises: [ArchivistConfigError].} =
  #: ArchivistConfigs =
  ## typically called internally from the test suite, sets a log file path to
  ## be created during the test run, for a specified node in the group
  # var config = self
  self.addCliOption("--log-file", logFile)
  # return startConfig

proc withLogLevel*(
    self: ArchivistConfig, level: LogLevel | string
): ArchivistConfig {.raises: [ArchivistConfigError].} =
  var config = self
  config.addCliOption("--log-level", $level)
  return config

proc withLogLevel*(
    self: ArchivistConfigs, idx: int, level: LogLevel | string
): ArchivistConfigs {.raises: [ArchivistConfigError].} =
  self.checkBounds idx

  var startConfig = self
  startConfig.configs[idx].addCliOption("--log-level", $level)
  return startConfig

proc withLogLevel*(
    self: ArchivistConfigs, level: LogLevel | string
): ArchivistConfigs {.raises: [ArchivistConfigError].} =
  var startConfig = self
  for config in startConfig.configs.mitems:
    config.addCliOption("--log-level", $level)
  return startConfig

proc withBlockTtl*(
    self: ArchivistConfig, ttl: int
): ArchivistConfig {.raises: [ArchivistConfigError].} =
  var config = self
  config.addCliOption("--block-ttl", $ttl)
  return config

proc withBlockTtl*(
    self: ArchivistConfigs, idx: int, ttl: int
): ArchivistConfigs {.raises: [ArchivistConfigError].} =
  self.checkBounds idx

  var startConfig = self
  startConfig.configs[idx].addCliOption("--block-ttl", $ttl)
  return startConfig

proc withBlockTtl*(
    self: ArchivistConfigs, ttl: int
): ArchivistConfigs {.raises: [ArchivistConfigError].} =
  var startConfig = self
  for config in startConfig.configs.mitems:
    config.addCliOption("--block-ttl", $ttl)
  return startConfig

proc withBlockMaintenanceInterval*(
    self: ArchivistConfig, interval: int
): ArchivistConfig {.raises: [ArchivistConfigError].} =
  var config = self
  config.addCliOption("--block-mi", $interval)
  return config

proc withBlockMaintenanceInterval*(
    self: ArchivistConfigs, idx: int, interval: int
): ArchivistConfigs {.raises: [ArchivistConfigError].} =
  self.checkBounds idx

  var startConfig = self
  startConfig.configs[idx].addCliOption("--block-mi", $interval)
  return startConfig

proc withBlockMaintenanceInterval*(
    self: ArchivistConfigs, interval: int
): ArchivistConfigs {.raises: [ArchivistConfigError].} =
  var startConfig = self
  for config in startConfig.configs.mitems:
    config.addCliOption("--block-mi", $interval)
  return startConfig

proc withSimulateProofFailures*(
    self: ArchivistConfigs, idx: int, failEveryNProofs: int
): ArchivistConfigs {.raises: [ArchivistConfigError].} =
  self.checkBounds idx

  var startConfig = self
  startConfig.configs[idx].addCliOption(
    StartUpCmd.persistence, "--simulate-proof-failures", $failEveryNProofs
  )
  return startConfig

proc withSimulateProofFailures*(
    self: ArchivistConfigs, failEveryNProofs: int
): ArchivistConfigs {.raises: [ArchivistConfigError].} =
  var startConfig = self
  for config in startConfig.configs.mitems:
    config.addCliOption(
      StartUpCmd.persistence, "--simulate-proof-failures", $failEveryNProofs
    )
  return startConfig

proc withValidationGroups*(
    self: ArchivistConfigs, groups: ValidationGroups
): ArchivistConfigs {.raises: [ArchivistConfigError].} =
  var startConfig = self
  for config in startConfig.configs.mitems:
    config.addCliOption(StartUpCmd.persistence, "--validator-groups", $(groups))
  return startConfig

proc withValidationGroupIndex*(
    self: ArchivistConfigs, idx: int, groupIndex: uint16
): ArchivistConfigs {.raises: [ArchivistConfigError].} =
  self.checkBounds idx

  var startConfig = self
  startConfig.configs[idx].addCliOption(
    StartUpCmd.persistence, "--validator-group-index", $groupIndex
  )
  return startConfig

proc withEthProvider*(
    self: ArchivistConfigs, idx: int, ethProvider: string
): ArchivistConfigs {.raises: [ArchivistConfigError].} =
  self.checkBounds idx

  var startConfig = self
  startConfig.configs[idx].addCliOption(
    StartUpCmd.persistence, "--eth-provider", ethProvider
  )
  return startConfig

proc withEthProvider*(
    self: ArchivistConfigs, ethProvider: string
): ArchivistConfigs {.raises: [ArchivistConfigError].} =
  var startConfig = self
  for config in startConfig.configs.mitems:
    config.addCliOption(StartUpCmd.persistence, "--eth-provider", ethProvider)
  return startConfig

proc logLevelWithTopics(
    config: ArchivistConfig, topics: varargs[string]
): string {.raises: [ArchivistConfigError].} =
  convertError:
    var logLevel = LogLevel.INFO
    let built = config.buildConfig("Invalid node config cli params")
    logLevel = parseEnum[LogLevel](built.logLevel.toUpperAscii)
    let level = $logLevel & ";TRACE: " & topics.join(",")
    return level

proc withLogTopics*(
    self: ArchivistConfigs, idx: int, topics: varargs[string]
): ArchivistConfigs {.raises: [ArchivistConfigError].} =
  self.checkBounds idx

  convertError:
    let config = self.configs[idx]
    let level = config.logLevelWithTopics(topics)
    var startConfig = self
    return startConfig.withLogLevel(idx, level)

proc withLogTopics*(
    self: ArchivistConfigs, topics: varargs[string]
): ArchivistConfigs {.raises: [ArchivistConfigError].} =
  var startConfig = self
  for config in startConfig.configs.mitems:
    let level = config.logLevelWithTopics(topics)
    config = config.withLogLevel(level)
  return startConfig

proc withStorageQuota*(
    self: ArchivistConfigs, idx: int, quota: NBytes
): ArchivistConfigs {.raises: [ArchivistConfigError].} =
  self.checkBounds idx

  var startConfig = self
  startConfig.configs[idx].addCliOption("--storage-quota", $quota)
  return startConfig

proc withStorageQuota*(
    self: ArchivistConfigs, quota: NBytes
): ArchivistConfigs {.raises: [ArchivistConfigError].} =
  var startConfig = self
  for config in startConfig.configs.mitems:
    config.addCliOption("--storage-quota", $quota)
  return startConfig
