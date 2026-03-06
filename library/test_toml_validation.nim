## TOML Validation Tests
##
## Comprehensive tests for the TOML validation module to ensure
## all validation functions work correctly.

import std/[unittest, strutils]
import results
import ./toml_validation

suite "TOML Validation Tests":
  
  suite "Size Validation":
    test "Empty TOML should pass size validation":
      let result = validateSize("")
      check result.isOk
    
    test "Small TOML should pass size validation":
      let toml = "logLevel = \"info\""
      let result = validateSize(toml)
      check result.isOk
    
    test "TOML at max size should pass validation":
      let toml = "a".repeat(DefaultMaxSize)
      let result = validateSize(toml)
      check result.isOk
    
    test "TOML exceeding max size should fail validation":
      let toml = "a".repeat(DefaultMaxSize + 1)
      let result = validateSize(toml)
      check result.isErr
      check "exceeds maximum size" in result.error.message
    
    test "Custom max size should be respected":
      let config = TomlValidationConfig(maxSize: 100)
      let toml = "a".repeat(101)
      let result = validateSize(toml, config)
      check result.isErr
  
  suite "Line Length Validation":
    test "Normal lines should pass validation":
      let toml = """
logLevel = "info"
logFormat = "auto"
"""
      let result = validateLineLength(toml)
      check result.isOk
    
    test "Line at max length should pass validation":
      let toml = "a".repeat(DefaultMaxLineLength)
      let result = validateLineLength(toml)
      check result.isOk
    
    test "Line exceeding max length should fail validation":
      let toml = "a".repeat(DefaultMaxLineLength + 1)
      let result = validateLineLength(toml)
      check result.isErr
      check "exceeds maximum length" in result.error.message
      check result.error.line == 1
    
    test "Custom max line length should be respected":
      let config = TomlValidationConfig(maxLineLength: 50)
      let toml = "a".repeat(51)
      let result = validateLineLength(toml, config)
      check result.isErr
  
  suite "Syntax Validation":
    test "Valid TOML should pass syntax validation":
      let toml = """
logLevel = "info"
logFormat = "auto"
metricsEnabled = true
"""
      let result = validateSyntax(toml)
      check result.isOk
    
    test "TOML with table headers should pass validation":
      let toml = """
[section]
key = "value"
"""
      let result = validateSyntax(toml)
      check result.isOk
    
    test "TOML with inline tables should pass validation":
      let toml = """
[section]
key = { name = "value" }
"""
      let result = validateSyntax(toml)
      check result.isOk
    
    test "TOML with inline tables disabled should fail":
      let config = TomlValidationConfig(allowInlineTables: false)
      let toml = "key = { name = \"value\" }"
      let result = validateSyntax(toml, config)
      check result.isErr
      check "Inline tables are not allowed" in result.error.message
    
    test "Unmatched closing bracket should fail validation":
      let toml = """
[section]
key = "value"
]
"""
      let result = validateSyntax(toml)
      check result.isErr
      check "Unmatched closing bracket" in result.error.message
    
    test "Unmatched opening bracket should fail validation":
      let toml = """
[section
key = "value"
"""
      let result = validateSyntax(toml)
      check result.isErr
      check "Unclosed bracket" in result.error.message
    
    test "Unmatched closing brace should fail validation":
      let toml = """
key = { name = "value" }
}
"""
      let result = validateSyntax(toml)
      check result.isErr
      check "Unmatched closing brace" in result.error.message
    
    test "Null byte should fail validation":
      let toml = "key = \"value\0\""
      let result = validateSyntax(toml)
      check result.isErr
      check "Null byte" in result.error.message
    
    test "Invalid control character should fail validation":
      let toml = "key = \"value\x01\""
      let result = validateSyntax(toml)
      check result.isErr
      check "Invalid control character" in result.error.message
  
  suite "Security Validation":
    test "Clean TOML should pass security validation":
      let toml = """
logLevel = "info"
logFormat = "auto"
"""
      let result = validateSecurity(toml)
      check result.isOk
    
    test "Script injection should be detected":
      let toml = "key = \"<script>alert('xss')</script>\""
      let result = validateSecurity(toml)
      check result.isErr
      check "script injection" in result.error.message
    
    test "JavaScript injection should be detected":
      let toml = "key = \"javascript:alert('xss')\""
      let result = validateSecurity(toml)
      check result.isErr
      check "JavaScript injection" in result.error.message
    
    test "Data URI injection should be detected":
      let toml = "key = \"data:text/html,<script>alert('xss')</script>\""
      let result = validateSecurity(toml)
      check result.isErr
      check "data URI injection" in result.error.message
    
    test "Event handler injection should be detected":
      let toml = "key = \"onclick=alert('xss')\""
      let result = validateSecurity(toml)
      check result.isErr
      check "event handler injection" in result.error.message
    
    test "Template injection should be detected":
      let toml = "key = \"${malicious}\""
      let result = validateSecurity(toml)
      check result.isErr
      check "template injection" in result.error.message
    
    test "Path traversal should be detected":
      let toml = "key = \"../../etc/passwd\""
      let result = validateSecurity(toml)
      check result.isErr
      check "path traversal" in result.error.message
    
    test "URL-encoded path traversal should be detected":
      let toml = "key = \"%2e%2e%2fetc%2fpasswd\""
      let result = validateSecurity(toml)
      check result.isErr
      check "path traversal" in result.error.message
    
    test "Command injection should be detected":
      let toml = "key = \"value; rm -rf /\""
      let result = validateSecurity(toml)
      check result.isErr
      check "command injection" in result.error.message
    
    test "Pipe command injection should be detected":
      let toml = "key = \"value | cat /etc/passwd\""
      let result = validateSecurity(toml)
      check result.isErr
      check "command injection" in result.error.message
    
    test "Backtick command injection should be detected":
      let toml = "key = \"`malicious command`\""
      let result = validateSecurity(toml)
      check result.isErr
      check "command injection" in result.error.message
  
  suite "Port Validation":
    test "Valid port should pass validation":
      let result = validatePort("8080", "testPort")
      check result.isOk
    
    test "Port at minimum should pass validation":
      let result = validatePort("1", "testPort")
      check result.isOk
    
    test "Port at maximum should pass validation":
      let result = validatePort("65535", "testPort")
      check result.isOk
    
    test "Port below minimum should fail validation":
      let result = validatePort("0", "testPort")
      check result.isErr
      check "must be between" in result.error.message
    
    test "Port above maximum should fail validation":
      let result = validatePort("65536", "testPort")
      check result.isErr
      check "must be between" in result.error.message
    
    test "Invalid port string should fail validation":
      let result = validatePort("invalid", "testPort")
      check result.isErr
      check "not a valid integer" in result.error.message
  
  suite "IP Address Validation":
    test "Valid IPv4 address should pass validation":
      let result = validateIpAddress("127.0.0.1", "testAddress")
      check result.isOk
    
    test "Valid IPv4 address with high octets should pass":
      let result = validateIpAddress("192.168.255.255", "testAddress")
      check result.isOk
    
    test "IPv4 address with octet above 255 should fail":
      let result = validateIpAddress("192.168.256.1", "testAddress")
      check result.isErr
      check "between 0 and 255" in result.error.message
    
    test "Invalid IPv4 address should fail validation":
      let result = validateIpAddress("invalid", "testAddress")
      check result.isErr
      check "not a valid IPv4" in result.error.message
    
    test "Valid IPv6 address should pass validation":
      let result = validateIpAddress("::1", "testAddress")
      check result.isOk
    
    test "Valid IPv6 address with multiple segments should pass":
      let result = validateIpAddress("2001:db8::1", "testAddress")
      check result.isOk
  
  suite "MultiAddress Validation":
    test "Valid multiaddress should pass validation":
      let result = validateMultiAddress("/ip4/127.0.0.1/tcp/8080", "testMultiAddr")
      check result.isOk
    
    test "Multiaddress without leading slash should fail":
      let result = validateMultiAddress("ip4/127.0.0.1/tcp/8080", "testMultiAddr")
      check result.isErr
      check "must start with '/'" in result.error.message
    
    test "Multiaddress with null byte should fail":
      let result = validateMultiAddress("/ip4/127.0.0.1/tcp/8080\0", "testMultiAddr")
      check result.isErr
      check "contains invalid characters" in result.error.message
  
  suite "Duration Validation":
    test "Valid duration in seconds should pass":
      let result = validateDuration("60s", "testDuration")
      check result.isOk
    
    test "Valid duration in minutes should pass":
      let result = validateDuration("5m", "testDuration")
      check result.isOk
    
    test "Valid duration in hours should pass":
      let result = validateDuration("1h", "testDuration")
      check result.isOk
    
    test "Valid duration in days should pass":
      let result = validateDuration("1d", "testDuration")
      check result.isOk
    
    test "Valid duration in milliseconds should pass":
      let result = validateDuration("500ms", "testDuration")
      check result.isOk
    
    test "Empty duration should fail validation":
      let result = validateDuration("", "testDuration")
      check result.isErr
      check "empty value" in result.error.message
    
    test "Duration without numeric value should fail":
      let result = validateDuration("s", "testDuration")
      check result.isErr
      check "missing numeric value" in result.error.message
    
    test "Duration with invalid unit should fail":
      let result = validateDuration("60x", "testDuration")
      check result.isErr
      check "invalid unit" in result.error.message
    
    test "Negative duration should fail validation":
      let result = validateDuration("-60s", "testDuration")
      check result.isErr
      check "negative values not allowed" in result.error.message
  
  suite "Enum Validation":
    test "Valid enum value should pass":
      let result = validateEnum("info", "logLevel", ValidLogLevels)
      check result.isOk
    
    test "Invalid enum value should fail":
      let result = validateEnum("invalid", "logLevel", ValidLogLevels)
      check result.isErr
      check "must be one of" in result.error.message
  
  suite "Range Validation":
    test "Value within range should pass":
      let result = validateRange("100", "testValue", 1, 1000)
      check result.isOk
    
    test "Value at minimum should pass":
      let result = validateRange("1", "testValue", 1, 1000)
      check result.isOk
    
    test "Value at maximum should pass":
      let result = validateRange("1000", "testValue", 1, 1000)
      check result.isOk
    
    test "Value below minimum should fail":
      let result = validateRange("0", "testValue", 1, 1000)
      check result.isErr
      check "must be between" in result.error.message
    
    test "Value above maximum should fail":
      let result = validateRange("1001", "testValue", 1, 1000)
      check result.isErr
      check "must be between" in result.error.message
    
    test "Invalid integer string should fail":
      let result = validateRange("invalid", "testValue", 1, 1000)
      check result.isErr
      check "not a valid integer" in result.error.message
  
  suite "Boolean Validation":
    test "True should pass validation":
      let result = validateBoolean("true", "testBool")
      check result.isOk
    
    test "False should pass validation":
      let result = validateBoolean("false", "testBool")
      check result.isOk
    
    test "Uppercase TRUE should pass validation":
      let result = validateBoolean("TRUE", "testBool")
      check result.isOk
    
    test "Uppercase FALSE should pass validation":
      let result = validateBoolean("FALSE", "testBool")
      check result.isOk
    
    test "Invalid boolean should fail validation":
      let result = validateBoolean("invalid", "testBool")
      check result.isErr
      check "must be 'true' or 'false'" in result.error.message
  
  suite "File Path Validation":
    test "Valid file path should pass":
      let result = validateFilePath("/path/to/file", "testPath")
      check result.isOk
    
    test "Relative file path should pass":
      let result = validateFilePath("relative/path", "testPath")
      check result.isOk
    
    test "Empty file path should fail":
      let result = validateFilePath("", "testPath")
      check result.isErr
      check "empty value" in result.error.message
    
    test "File path with null byte should fail":
      let result = validateFilePath("/path\0/file", "testPath")
      check result.isErr
      check "contains null byte" in result.error.message
  
  suite "Ethereum Address Validation":
    test "Valid Ethereum address should pass":
      let result = validateEthAddress("0x1234567890123456789012345678901234567890", "testAddress")
      check result.isOk
    
    test "Empty Ethereum address should pass (optional field)":
      let result = validateEthAddress("", "testAddress")
      check result.isOk
    
    test "Ethereum address without 0x prefix should fail":
      let result = validateEthAddress("1234567890123456789012345678901234567890", "testAddress")
      check result.isErr
      check "must start with '0x'" in result.error.message
    
    test "Ethereum address with wrong length should fail":
      let result = validateEthAddress("0x123456789012345678901234567890123456789", "testAddress")
      check result.isErr
      check "must be 42 characters" in result.error.message
    
    test "Ethereum address with invalid hex should fail":
      let result = validateEthAddress("0x123456789012345678901234567890123456789g", "testAddress")
      check result.isErr
      check "invalid hex characters" in result.error.message
  
  suite "Content Validation":
    test "Valid logLevel should pass":
      let toml = "logLevel = \"info\""
      let result = validateContent(toml)
      check result.isOk
    
    test "Invalid logLevel should fail":
      let toml = "logLevel = \"invalid\""
      let result = validateContent(toml)
      check result.isErr
      check "logLevel" in result.error.message
    
    test "Valid logFormat should pass":
      let toml = "logFormat = \"auto\""
      let result = validateContent(toml)
      check result.isOk
    
    test "Invalid logFormat should fail":
      let toml = "logFormat = \"invalid\""
      let result = validateContent(toml)
      check result.isErr
      check "logFormat" in result.error.message
    
    test "Valid repoKind should pass":
      let toml = "repoKind = \"fs\""
      let result = validateContent(toml)
      check result.isOk
    
    test "Invalid repoKind should fail":
      let toml = "repoKind = \"invalid\""
      let result = validateContent(toml)
      check result.isErr
      check "repoKind" in result.error.message
    
    test "Valid proverBackend should pass":
      let toml = "proverBackend = \"nimgroth16\""
      let result = validateContent(toml)
      check result.isOk
    
    test "Invalid proverBackend should fail":
      let toml = "proverBackend = \"invalid\""
      let result = validateContent(toml)
      check result.isErr
      check "proverBackend" in result.error.message
    
    test "Valid curve should pass":
      let toml = "curve = \"bn128\""
      let result = validateContent(toml)
      check result.isOk
    
    test "Invalid curve should fail":
      let toml = "curve = \"invalid\""
      let result = validateContent(toml)
      check result.isErr
      check "curve" in result.error.message
    
    test "Valid metricsPort should pass":
      let toml = "metricsPort = 8008"
      let result = validateContent(toml)
      check result.isOk
    
    test "Invalid metricsPort should fail":
      let toml = "metricsPort = 99999"
      let result = validateContent(toml)
      check result.isErr
      check "metricsPort" in result.error.message
    
    test "Valid maxPeers should pass":
      let toml = "maxPeers = 160"
      let result = validateContent(toml)
      check result.isOk
    
    test "Invalid maxPeers should fail":
      let toml = "maxPeers = 99999"
      let result = validateContent(toml)
      check result.isErr
      check "maxPeers" in result.error.message
    
    test "Valid numThreads should pass":
      let toml = "numThreads = 4"
      let result = validateContent(toml)
      check result.isOk
    
    test "Invalid numThreads should fail":
      let toml = "numThreads = 999"
      let result = validateContent(toml)
      check result.isErr
      check "numThreads" in result.error.message
    
    test "Valid validatorMaxSlots should pass":
      let toml = "validatorMaxSlots = 1000"
      let result = validateContent(toml)
      check result.isOk
    
    test "Invalid validatorMaxSlots should fail":
      let toml = "validatorMaxSlots = -1"
      let result = validateContent(toml)
      check result.isErr
      check "validatorMaxSlots" in result.error.message
    
    test "Valid validatorGroups should pass":
      let toml = "validatorGroups = 16"
      let result = validateContent(toml)
      check result.isOk
    
    test "Invalid validatorGroups should fail":
      let toml = "validatorGroups = 1"
      let result = validateContent(toml)
      check result.isErr
      check "validatorGroups" in result.error.message
    
    test "Valid maxSlotDepth should pass":
      let toml = "maxSlotDepth = 16"
      let result = validateContent(toml)
      check result.isOk
    
    test "Invalid maxSlotDepth should fail":
      let toml = "maxSlotDepth = 100"
      let result = validateContent(toml)
      check result.isErr
      check "maxSlotDepth" in result.error.message
    
    test "Valid cacheSize should pass":
      let toml = "cacheSize = 0"
      let result = validateContent(toml)
      check result.isOk
    
    test "Invalid cacheSize should fail":
      let toml = "cacheSize = -1"
      let result = validateContent(toml)
      check result.isErr
      check "cacheSize" in result.error.message
    
    test "Valid storageQuota should pass":
      let toml = "storageQuota = 1073741824"
      let result = validateContent(toml)
      check result.isOk
    
    test "Invalid storageQuota should fail":
      let toml = "storageQuota = 0"
      let result = validateContent(toml)
      check result.isErr
      check "storageQuota" in result.error.message
    
    test "Valid blockTtl should pass":
      let toml = "blockTtl = 3600"
      let result = validateContent(toml)
      check result.isOk
    
    test "Invalid blockTtl should fail":
      let toml = "blockTtl = 100000"
      let result = validateContent(toml)
      check result.isErr
      check "blockTtl" in result.error.message
    
    test "Valid blockMaintenanceInterval should pass":
      let toml = "blockMaintenanceInterval = 3600"
      let result = validateContent(toml)
      check result.isOk
    
    test "Invalid blockMaintenanceInterval should fail":
      let toml = "blockMaintenanceInterval = 10"
      let result = validateContent(toml)
      check result.isErr
      check "blockMaintenanceInterval" in result.error.message
    
    test "Valid metricsAddress should pass":
      let toml = "metricsAddress = \"127.0.0.1\""
      let result = validateContent(toml)
      check result.isOk
    
    test "Invalid metricsAddress should fail":
      let toml = "metricsAddress = \"invalid\""
      let result = validateContent(toml)
      check result.isErr
      check "metricsAddress" in result.error.message
    
    test "Valid netPrivKeyFile should pass":
      let toml = "netPrivKeyFile = \"key\""
      let result = validateContent(toml)
      check result.isOk
    
    test "Invalid netPrivKeyFile should fail":
      let toml = "netPrivKeyFile = \"\""
      let result = validateContent(toml)
      check result.isErr
      check "netPrivKeyFile" in result.error.message
    
    test "Valid marketplaceAddress should pass":
      let toml = "marketplaceAddress = \"0x1234567890123456789012345678901234567890\""
      let result = validateContent(toml)
      check result.isOk
    
    test "Invalid marketplaceAddress should fail":
      let toml = "marketplaceAddress = \"invalid\""
      let result = validateContent(toml)
      check result.isErr
      check "marketplaceAddress" in result.error.message
    
    test "Comments should be ignored":
      let toml = """
# This is a comment
logLevel = "info"
# Another comment
"""
      let result = validateContent(toml)
      check result.isOk
    
    test "Table headers should be ignored":
      let toml = """
[section]
logLevel = "info"
"""
      let result = validateContent(toml)
      check result.isOk
  
  suite "Comprehensive TOML Validation":
    test "Empty TOML should pass all validations":
      let result = validateToml("")
      check result.isOk
    
    test "Valid TOML should pass all validations":
      let toml = """
logLevel = "info"
logFormat = "auto"
metricsEnabled = true
metricsPort = 8008
maxPeers = 160
numThreads = 4
"""
      let result = validateToml(toml)
      check result.isOk
    
    test "TOML with size violation should fail":
      let toml = "a".repeat(DefaultMaxSize + 1)
      let result = validateToml(toml)
      check result.isErr
    
    test "TOML with syntax error should fail":
      let toml = """
logLevel = "info"
]
"""
      let result = validateToml(toml)
      check result.isErr
    
    test "TOML with security issue should fail":
      let toml = "key = \"<script>alert('xss')</script>\""
      let result = validateToml(toml)
      check result.isErr
    
    test "TOML with invalid content should fail":
      let toml = "logLevel = \"invalid\""
      let result = validateToml(toml)
      check result.isErr
    
    test "Complex valid TOML should pass all validations":
      let toml = """
logLevel = "info"
logFormat = "auto"
metricsEnabled = true
metricsAddress = "127.0.0.1"
metricsPort = 8008
dataDir = "/tmp/archivist"
listenAddrs = ["/ip4/0.0.0.0/tcp/0"]
nat = "any"
discoveryPort = 8090
netPrivKeyFile = "key"
maxPeers = 160
numThreads = 4
agentString = "Archivist Node"
apiBindAddress = "127.0.0.1"
apiPort = 8080
repoKind = "fs"
storageQuota = 1073741824
blockTtl = 3600
blockMaintenanceInterval = 3600
blockMaintenanceNumberOfBlocks = 100
cacheSize = 0
persistence = false
ethProvider = "ws://localhost:8545"
useSystemClock = false
validator = false
prover = false
circuitDir = "/tmp/archivist/circuits"
proverBackend = "nimgroth16"
curve = "bn128"
numProofSamples = 10
maxSlotDepth = 16
maxDatasetDepth = 16
maxBlockDepth = 16
maxCellElms = 256
"""
      let result = validateToml(toml)
      check result.isOk
  
  suite "CString Validation":
    test "nil cstring should pass validation":
      let result = validateTomlCString(nil)
      check result.isOk
    
    test "Valid cstring should pass validation":
      let toml = "logLevel = \"info\""
      let result = validateTomlCString(toml)
      check result.isOk
    
    test "Invalid cstring should fail validation":
      let toml = "logLevel = \"invalid\""
      let result = validateTomlCString(toml)
      check result.isErr
  
  suite "Error Formatting":
    test "Error without line/column should format correctly":
      let error = createValidationError("Test error message")
      let formatted = formatError(error)
      check "TOML validation error: Test error message" == formatted
    
    test "Error with line should format correctly":
      let error = createValidationError("Test error message", line = 10)
      let formatted = formatError(error)
      check "line 10" in formatted
      check "Test error message" in formatted
    
    test "Error with line and column should format correctly":
      let error = createValidationError("Test error message", line = 10, column = 5)
      let formatted = formatError(error)
      check "line 10, column 5" in formatted
      check "Test error message" in formatted
    
    test "Error with context should format correctly":
      let error = createValidationError("Test error message", context = "Additional context")
      let formatted = formatError(error)
      check "Test error message" in formatted
      check "Additional context" in formatted
