## TOML Input Validation Module
##
## This module provides comprehensive validation for TOML configuration input
## to prevent security issues and provide better error messages.
##
## Features:
## - Size limits to prevent resource exhaustion
## - Syntax validation before parsing
## - Content validation for specific configuration values
## - Security validation to prevent injection attacks
## - Clear, actionable error messages

{.push raises: [].}

import std/[strutils, re, parseutils, unicode]
import results

type
  TomlValidationError* = object
    message*: string
    line*: int
    column*: int
    context*: string

  TomlValidationResult* = Result[void, TomlValidationError]

  TomlValidationConfig* = object
    maxSize*: int
    maxLineLength*: int
    maxNestingDepth*: int
    maxArrayLength*: int
    allowInlineTables*: bool
    allowMultilineStrings*: bool

const
  DefaultMaxSize* = 1_000_000  # 1MB max TOML size
  DefaultMaxLineLength* = 10_000  # 10KB max line length
  DefaultMaxNestingDepth* = 50  # Max nesting depth for tables
  DefaultMaxArrayLength* = 10_000  # Max array elements
  DefaultValidationConfig* = TomlValidationConfig(
    maxSize: DefaultMaxSize,
    maxLineLength: DefaultMaxLineLength,
    maxNestingDepth: DefaultMaxNestingDepth,
    maxArrayLength: DefaultMaxArrayLength,
    allowInlineTables: true,
    allowMultilineStrings: true
  )

  ValidLogLevels* = ["trace", "debug", "info", "notice", "warn", "error", "fatal"]

  ValidLogFormats* = ["auto", "colors", "nocolors", "json", "none"]

  ValidRepoKinds* = ["fs", "sqlite", "leveldb"]

  ValidProverBackends* = ["nimgroth16", "circomcompat"]

  ValidCurves* = ["bn128"]

  ValidNatStrategies* = ["any", "none", "upnp", "pmp"]

  ValidPortRange* = 1..65535

  ValidThreadCountRange* = 0..256

  ValidValidatorGroupsRange* = 2..65535

  ValidMaxSlotsRange* = 0..1000000

  ValidMaxDepthRange* = 1..64

  ValidMaxCellElementsRange* = 1..256

  ValidCacheSizeRange* = 0..1_000_000_000  # 0 to 1GB

  ValidStorageQuotaRange* = 1_048_576..1_000_000_000_000  # 1MB to 1TB

  ValidBlockTtlRange* = 0..86400  # 0 to 24 hours

  ValidBlockMaintenanceIntervalRange* = 60..86400  # 1 minute to 24 hours

  ValidBlockMaintenanceNumberOfBlocksRange* = 1..100000

  ValidMaxPeersRange* = 1..1000

  ValidDiscoveryPortRange* = 1024..65535

  ValidMetricsPortRange* = 1024..65535

  ValidApiPortRange* = 1024..65535

  ValidMaxPriorityFeePerGasRange* = 0..1_000_000_000_000  # 0 to 1 trillion wei

  ValidNumProofSamplesRange* = 1..1000

  ValidMarketplaceRequestCacheSizeRange* = 1..65535

  ValidValidatorGroupIndexRange* = 0..65534

proc createValidationError*(
  message: string,
  line: int = 0,
  column: int = 0,
  context: string = ""
): TomlValidationError =
  TomlValidationError(
    message: message,
    line: line,
    column: column,
    context: context
  )

proc formatError*(error: TomlValidationError): string =
  if error.line > 0:
    if error.column > 0:
      result = "TOML validation error at line $1, column $2: $3" % [
        $error.line, $error.column, error.message
      ]
    else:
      result = "TOML validation error at line $1: $2" % [
        $error.line, error.message
      ]
  else:
    result = "TOML validation error: $1" % [error.message]
  
  if error.context.len > 0:
    result.add("\nContext: " & error.context)

proc validateSize*(toml: string, config: TomlValidationConfig = DefaultValidationConfig): TomlValidationResult =
  if toml.len > config.maxSize:
    return err(createValidationError(
      "TOML configuration exceeds maximum size of $1 bytes (got $2 bytes)" % [
        $config.maxSize, $toml.len
      ]
    ))
  return ok()

proc validateLineLength*(toml: string, config: TomlValidationConfig = DefaultValidationConfig): TomlValidationResult =
  var lineNum = 1
  for line in toml.splitLines():
    if line.len > config.maxLineLength:
      return err(createValidationError(
        "Line exceeds maximum length of $1 characters (got $2 characters)" % [
          $config.maxLineLength, $line.len
        ],
        line = lineNum
      ))
    lineNum += 1
  return ok()

proc validateSyntax*(toml: string, config: TomlValidationConfig = DefaultValidationConfig): TomlValidationResult =  
  var lineNum = 1
  var columnNum = 1
  var i = 0
  let len = toml.len
  
  while i < len:
    let c = toml[i]
    
    # Check for null bytes
    if c == '\0':
      return err(createValidationError(
        "Null byte found in TOML configuration",
        line = lineNum,
        column = columnNum
      ))
    
    # Check for control characters (except newline, tab, and carriage return)
    if c < ' ' and c notin {'\n', '\t', '\r'}:
      return err(createValidationError(
        "Invalid control character found in TOML configuration",
        line = lineNum,
        column = columnNum
      ))
    
    # Track line and column numbers
    if c == '\n':
      lineNum += 1
      columnNum = 1
    elif c == '\r':
      # Skip carriage return if followed by newline
      if i + 1 < len and toml[i + 1] == '\n':
        i += 1
      lineNum += 1
      columnNum = 1
    else:
      columnNum += 1
    
    i += 1
  
  # Check for balanced brackets
  var bracketStack: seq[char] = @[]
  lineNum = 1
  columnNum = 1
  i = 0
  
  while i < len:
    let c = toml[i]
    
    case c
    of '[':
      bracketStack.add('[')
    of ']':
      if bracketStack.len == 0 or bracketStack[^1] != '[':
        return err(createValidationError(
          "Unmatched closing bracket ']'",
          line = lineNum,
          column = columnNum
        ))
      bracketStack.delete(bracketStack.high)
    of '{':
      if not config.allowInlineTables:
        return err(createValidationError(
          "Inline tables are not allowed",
          line = lineNum,
          column = columnNum
        ))
      bracketStack.add('{')
    of '}':
      if bracketStack.len == 0 or bracketStack[^1] != '{':
        return err(createValidationError(
          "Unmatched closing brace '}'",
          line = lineNum,
          column = columnNum
        ))
      bracketStack.delete(bracketStack.high)
    else:
      discard
    
    # Track line and column numbers
    if c == '\n':
      lineNum += 1
      columnNum = 1
    elif c == '\r':
      if i + 1 < len and toml[i + 1] == '\n':
        i += 1
      lineNum += 1
      columnNum = 1
    else:
      columnNum += 1
    
    i += 1
  
  # Check for unclosed brackets
  if bracketStack.len > 0:
    let unclosed = bracketStack[^1]
    return err(createValidationError(
      "Unclosed bracket '$1' found at end of TOML configuration" % [$unclosed],
      line = lineNum,
      column = columnNum
    ))
  
  return ok()

proc validateSecurity*(toml: string): TomlValidationResult =  
  let suspiciousPatterns = [
    (re"<script[^>]*>.*?</script>", "Potential script injection"),
    (re"javascript:", "Potential JavaScript injection"),
    (re"data:text/html", "Potential data URI injection"),
    (re"on\\w+\\s*=", "Potential event handler injection"),
    (re"\\$\\{.*?\\}", "Potential template injection"),
    (re"\\x[0-9a-fA-F]{2}", "Potential hex escape injection"),
    (re"\\u[0-9a-fA-F]{4}", "Potential Unicode escape injection"),
    (re"\\U[0-9a-fA-F]{8}", "Potential Unicode escape injection"),
    (re"\\n\\s*\\n\\s*\\n", "Excessive blank lines (potential DoS)"),
    (re"\\[\\s*\\[\\s*\\[", "Excessive array nesting (potential DoS)"),
  ]
  
  for (pattern, description) in suspiciousPatterns:
    if toml.find(pattern) != -1:
      return err(createValidationError(
        "Security validation failed: $1" % [description]
      ))
  
  # Check for path traversal attempts
  let pathTraversalPatterns = [
    re"\\.\\.[\\\\/]",
    re"%2e%2e",
    re"%252e%252e",
  ]
  
  for pattern in pathTraversalPatterns:
    if toml.find(pattern) != -1:
      return err(createValidationError(
        "Security validation failed: potential path traversal attempt detected"
      ))
  
  # Check for command injection patterns
  let commandInjectionPatterns = [
    re";\\s*\\w+\\s*=",
    re"\\|\\s*\\w+",
    re"`[^`]*`",
    re"\\$\\([^)]*\\)",
    re"\\$\\{[^}]*\\}",
  ]
  
  for pattern in commandInjectionPatterns:
    if toml.find(pattern) != -1:
      return err(createValidationError(
        "Security validation failed: potential command injection attempt detected"
      ))
  
  return ok()

proc validatePort*(value: string, fieldName: string): TomlValidationResult =
  ## Validate a port number
  try:
    let port = parseInt(value)
    if port notin ValidPortRange:
      return err(createValidationError(
        "Invalid port number '$1' for field '$2': must be between $3 and $4" % [
          value, fieldName, $ValidPortRange.a, $ValidPortRange.b
        ]
      ))
  except ValueError:
    return err(createValidationError(
      "Invalid port number '$1' for field '$2': not a valid integer" % [
        value, fieldName
      ]
    ))
  return ok()

proc validateIpAddress*(value: string, fieldName: string): TomlValidationResult =
  let ipv4Pattern = re"^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$"
  if value.match(ipv4Pattern):
    let parts = value.split('.')
    for part in parts:
      try:
        let num = parseInt(part)
        if num < 0 or num > 255:
          return err(createValidationError(
            "Invalid IP address '$1' for field '$2': each octet must be between 0 and 255" % [
              value, fieldName
            ]
          ))
      except ValueError:
        return err(createValidationError(
          "Invalid IP address '$1' for field '$2': not a valid IPv4 address" % [
            value, fieldName
          ]
        ))
    return ok()
  
  let ipv6Pattern = re"^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$"
  if value.match(ipv6Pattern):
    return ok()
  
  return err(createValidationError(
    "Invalid IP address '$1' for field '$2': not a valid IPv4 or IPv6 address" % [
      value, fieldName
    ]
  ))

proc validateMultiAddress*(value: string, fieldName: string): TomlValidationResult =
  if not value.startsWith('/'):
    return err(createValidationError(
      "Invalid multiaddress '$1' for field '$2': must start with '/'" % [
        value, fieldName
      ]
    ))
  
  let suspiciousChars = {'\0', '\n', '\r', '\t'}
  for c in value:
    if c in suspiciousChars:
      return err(createValidationError(
        "Invalid multiaddress '$1' for field '$2': contains invalid characters" % [
          value, fieldName
        ]
      ))
  
  return ok()

proc validateDuration*(value: string, fieldName: string): TomlValidationResult =
  if value.len == 0:
    return err(createValidationError(
      "Invalid duration for field '$1': empty value" % [fieldName]
    ))
  
  var numStr = ""
  var unit = ""
  var i = 0
  
  while i < value.len and value[i] in {'0'..'9'}:
    numStr.add(value[i])
    i += 1
  
  if i < value.len:
    unit = value[i..^1]
  
  if numStr.len == 0:
    return err(createValidationError(
      "Invalid duration '$1' for field '$2': missing numeric value" % [
        value, fieldName
      ]
    ))
  
  try:
    let num = parseInt(numStr)
    if num < 0:
      return err(createValidationError(
        "Invalid duration '$1' for field '$2': negative values not allowed" % [
          value, fieldName
        ]
      ))
  except ValueError:
    return err(createValidationError(
      "Invalid duration '$1' for field '$2': not a valid number" % [
        value, fieldName
      ]
    ))
  
  let validUnits = ["s", "m", "h", "d", "ms", "us", "ns"]
  if unit.len == 0 or unit notin validUnits:
    return err(createValidationError(
      "Invalid duration '$1' for field '$2': invalid unit '$3' (must be one of: $4)" % [
        value, fieldName, unit, validUnits.join(", ")
      ]
    ))
  
  return ok()

proc validateEnum*(value: string, fieldName: string, validValues: seq[string]): TomlValidationResult =
  if value notin validValues:
    return err(createValidationError(
      "Invalid value '$1' for field '$2': must be one of: $3" % [
        value, fieldName, validValues.join(", ")
      ]
    ))
  return ok()

proc validateRange*(value: string, fieldName: string, minVal: int, maxVal: int): TomlValidationResult =
  try:
    let num = parseInt(value)
    if num < minVal or num > maxVal:
      return err(createValidationError(
        "Invalid value '$1' for field '$2': must be between $3 and $4" % [
          value, fieldName, $minVal, $maxVal
        ]
      ))
  except ValueError:
    return err(createValidationError(
      "Invalid value '$1' for field '$2': not a valid integer" % [
        value, fieldName
      ]
    ))
  return ok()

proc validateBoolean*(value: string, fieldName: string): TomlValidationResult =
  let lowerValue = value.toLowerAscii()
  if lowerValue notin ["true", "false"]:
    return err(createValidationError(
      "Invalid boolean value '$1' for field '$2': must be 'true' or 'false'" % [
        value, fieldName
      ]
    ))
  return ok()

proc validateFilePath*(value: string, fieldName: string): TomlValidationResult =
  if value.len == 0:
    return err(createValidationError(
      "Invalid file path for field '$1': empty value" % [fieldName]
    ))
  
  if '\0' in value:
    return err(createValidationError(
      "Invalid file path '$1' for field '$2': contains null byte" % [
        value, fieldName
      ]
    ))
  
  let suspiciousChars = {'\0', '\n', '\r'}
  for c in value:
    if c in suspiciousChars:
      return err(createValidationError(
        "Invalid file path '$1' for field '$2': contains invalid characters" % [
          value, fieldName
        ]
      ))
  
  return ok()

proc validateEthAddress*(value: string, fieldName: string): TomlValidationResult =
  if value.len == 0:
    return ok()
  
  if value.len != 42:
    return err(createValidationError(
      "Invalid Ethereum address '$1' for field '$2': must be 42 characters (0x + 40 hex digits)" % [
        value, fieldName
      ]
    ))
  
  if not value.startsWith("0x"):
    return err(createValidationError(
      "Invalid Ethereum address '$1' for field '$2': must start with '0x'" % [
        value, fieldName
      ]
    ))
  
  let hexPart = value[2..^1]
  let hexPattern = re"^[0-9a-fA-F]{40}$"
  if not hexPart.match(hexPattern):
    return err(createValidationError(
      "Invalid Ethereum address '$1' for field '$2': contains invalid hex characters" % [
        value, fieldName
      ]
    ))
  
  return ok()

proc validateContent*(toml: string): TomlValidationResult =
  var lineNum = 1
  for line in toml.splitLines():
    let trimmed = line.strip()
    
    if trimmed.len == 0 or trimmed.startsWith('#'):
      lineNum += 1
      continue
    
    if trimmed.startsWith('[') and trimmed.endsWith(']'):
      lineNum += 1
      continue
    
    let eqPos = trimmed.find('=')
    if eqPos > 0:
      let key = trimmed[0..<eqPos].strip()
      let value = trimmed[eqPos+1..^1].strip()
      
      var unquotedValue = value
      if (value.startsWith('"') and value.endsWith('"')) or
         (value.startsWith('\'') and value.endsWith('\'')):
        unquotedValue = value[1..^2]
      
      case key
      of "logLevel":
        let result = validateEnum(unquotedValue, key, ValidLogLevels)
        if result.isErr:
          var err = result.error
          err.line = lineNum
          return err
      
      of "logFormat":
        let result = validateEnum(unquotedValue, key, ValidLogFormats)
        if result.isErr:
          var err = result.error
          err.line = lineNum
          return err
      
      of "repoKind":
        let result = validateEnum(unquotedValue, key, ValidRepoKinds)
        if result.isErr:
          var err = result.error
          err.line = lineNum
          return err
      
      of "proverBackend":
        let result = validateEnum(unquotedValue, key, ValidProverBackends)
        if result.isErr:
          var err = result.error
          err.line = lineNum
          return err
      
      of "curve":
        let result = validateEnum(unquotedValue, key, ValidCurves)
        if result.isErr:
          var err = result.error
          err.line = lineNum
          return err
      
      of "metricsPort":
        let result = validatePort(unquotedValue, key)
        if result.isErr:
          var err = result.error
          err.line = lineNum
          return err
      
      of "discoveryPort":
        let result = validateRange(unquotedValue, key, ValidDiscoveryPortRange.a, ValidDiscoveryPortRange.b)
        if result.isErr:
          var err = result.error
          err.line = lineNum
          return err
      
      of "apiPort":
        let result = validateRange(unquotedValue, key, ValidApiPortRange.a, ValidApiPortRange.b)
        if result.isErr:
          var err = result.error
          err.line = lineNum
          return err
      
      of "maxPeers":
        let result = validateRange(unquotedValue, key, ValidMaxPeersRange.a, ValidMaxPeersRange.b)
        if result.isErr:
          var err = result.error
          err.line = lineNum
          return err
      
      of "numThreads":
        let result = validateRange(unquotedValue, key, ValidThreadCountRange.a, ValidThreadCountRange.b)
        if result.isErr:
          var err = result.error
          err.line = lineNum
          return err
      
      of "validatorMaxSlots":
        let result = validateRange(unquotedValue, key, ValidMaxSlotsRange.a, ValidMaxSlotsRange.b)
        if result.isErr:
          var err = result.error
          err.line = lineNum
          return err
      
      of "validatorGroups":
        let result = validateRange(unquotedValue, key, ValidValidatorGroupsRange.a, ValidValidatorGroupsRange.b)
        if result.isErr:
          var err = result.error
          err.line = lineNum
          return err
      
      of "validatorGroupIndex":
        let result = validateRange(unquotedValue, key, ValidValidatorGroupIndexRange.a, ValidValidatorGroupIndexRange.b)
        if result.isErr:
          var err = result.error
          err.line = lineNum
          return err
      
      of "maxSlotDepth", "maxDatasetDepth", "maxBlockDepth":
        let result = validateRange(unquotedValue, key, ValidMaxDepthRange.a, ValidMaxDepthRange.b)
        if result.isErr:
          var err = result.error
          err.line = lineNum
          return err
      
      of "maxCellElms":
        let result = validateRange(unquotedValue, key, ValidMaxCellElementsRange.a, ValidMaxCellElementsRange.b)
        if result.isErr:
          var err = result.error
          err.line = lineNum
          return err
      
      of "cacheSize":
        let result = validateRange(unquotedValue, key, ValidCacheSizeRange.a, ValidCacheSizeRange.b)
        if result.isErr:
          var err = result.error
          err.line = lineNum
          return err
      
      of "storageQuota":
        let result = validateRange(unquotedValue, key, ValidStorageQuotaRange.a, ValidStorageQuotaRange.b)
        if result.isErr:
          var err = result.error
          err.line = lineNum
          return err
      
      of "blockTtl":
        let result = validateRange(unquotedValue, key, ValidBlockTtlRange.a, ValidBlockTtlRange.b)
        if result.isErr:
          var err = result.error
          err.line = lineNum
          return err
      
      of "blockMaintenanceInterval":
        let result = validateRange(unquotedValue, key, ValidBlockMaintenanceIntervalRange.a, ValidBlockMaintenanceIntervalRange.b)
        if result.isErr:
          var err = result.error
          err.line = lineNum
          return err
      
      of "blockMaintenanceNumberOfBlocks":
        let result = validateRange(unquotedValue, key, ValidBlockMaintenanceNumberOfBlocksRange.a, ValidBlockMaintenanceNumberOfBlocksRange.b)
        if result.isErr:
          var err = result.error
          err.line = lineNum
          return err
      
      of "maxPriorityFeePerGas":
        let result = validateRange(unquotedValue, key, ValidMaxPriorityFeePerGasRange.a, ValidMaxPriorityFeePerGasRange.b)
        if result.isErr:
          var err = result.error
          err.line = lineNum
          return err
      
      of "numProofSamples":
        let result = validateRange(unquotedValue, key, ValidNumProofSamplesRange.a, ValidNumProofSamplesRange.b)
        if result.isErr:
          var err = result.error
          err.line = lineNum
          return err
      
      of "marketplaceRequestCacheSize":
        let result = validateRange(unquotedValue, key, ValidMarketplaceRequestCacheSizeRange.a, ValidMarketplaceRequestCacheSizeRange.b)
        if result.isErr:
          var err = result.error
          err.line = lineNum
          return err
      
      of "metricsAddress", "apiBindAddress":
        let result = validateIpAddress(unquotedValue, key)
        if result.isErr:
          var err = result.error
          err.line = lineNum
          return err
      
      of "netPrivKeyFile", "logFile", "circomR1cs", "circomGraph", "circomWasm", "circomZkey":
        let result = validateFilePath(unquotedValue, key)
        if result.isErr:
          var err = result.error
          err.line = lineNum
          return err
      
      of "marketplaceAddress", "ethPrivateKey":
        let result = validateEthAddress(unquotedValue, key)
        if result.isErr:
          var err = result.error
          err.line = lineNum
          return err
      
      of "blockTtl", "blockMaintenanceInterval":
        let result = validateDuration(unquotedValue, key)
        if result.isErr:
          var err = result.error
          err.line = lineNum
          return err
      
      else:
        discard
    
    lineNum += 1
  
  return ok()

proc validateToml*(
  toml: string,
  config: TomlValidationConfig = DefaultValidationConfig
): TomlValidationResult =
  if toml.len == 0:
    return ok()
  
  let sizeResult = validateSize(toml, config)
  if sizeResult.isErr:
    return sizeResult
  
  let lineLengthResult = validateLineLength(toml, config)
  if lineLengthResult.isErr:
    return lineLengthResult
  
  let syntaxResult = validateSyntax(toml, config)
  if syntaxResult.isErr:
    return syntaxResult
  
  let securityResult = validateSecurity(toml)
  if securityResult.isErr:
    return securityResult
  
  let contentResult = validateContent(toml)
  if contentResult.isErr:
    return contentResult
  
  return ok()

proc validateTomlCString*(
  toml: cstring,
  config: TomlValidationConfig = DefaultValidationConfig
): TomlValidationResult =
  if toml.isNil:
    return ok()
  
  let tomlStr = $toml
  return validateToml(tomlStr, config)

{.pop.}
