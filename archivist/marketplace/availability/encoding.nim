import std/json
import std/options
import std/parseutils
import pkg/questionable
import pkg/questionable/results
import pkg/stew/byteutils
import pkg/stint
import ../timestamps
import ../tokens
import ./terms

{.push raises: [].}

func encode*(terms: AvailabilityTerms): seq[byte] =
  let json =
    %*{
      "version": 2,
      "minimumPricePerBytePerSecond": terms.minimumPricePerBytePerSecond,
      "maximumCollateralPerByte": terms.maximumCollateralPerByte,
      "maximumDuration": terms.maximumDuration,
      "availableUntil": terms.availableUntil,
    }
  ($json).toBytes

proc getUInt256(json: JsonNode): ?UInt256 =
  let decimals = json.getStr()
  if decimals == "":
    return none UInt256
  try:
    return some UInt256.fromDecimal(decimals)
  except ValueError:
    return none UInt256

proc getInt64(json: JsonNode): ?int64 =
  if json == nil:
    return none int64
  if json.kind != JInt:
    return none int64
  some json.getBiggestInt()

proc getUInt64(json: JsonNode): ?uint64 =
  let decimals = json.getStr()
  if decimals == "":
    return none uint64
  try:
    var parsed: uint64
    if parseBiggestUint(decimals, parsed) == decimals.len:
      some parsed
    else:
      none uint64
  except ValueError:
    none uint64

proc getTokensPerSecond(json: JsonNode): ?TokensPerSecond =
  let decimals = json.getStr()
  if decimals == "":
    return none TokensPerSecond
  try:
    return some TokensPerSecond.init(StUint[96].fromDecimal(decimals))
  except ValueError:
    return none TokensPerSecond

proc getTokens(json: JsonNode): ?Tokens =
  let decimals = json.getStr()
  if decimals == "":
    return none Tokens
  try:
    return some Tokens.init(UInt128.fromDecimal(decimals))
  except ValueError:
    return none Tokens

proc getStorageDuration(json: JsonNode): ?StorageDuration =
  let decimals = json.getStr()
  if decimals == "":
    return none StorageDuration
  try:
    return some StorageDuration.init(StUint[40].fromDecimal(decimals))
  except ValueError:
    return none StorageDuration

proc getStorageTimestamp(json: JsonNode): ?StorageTimestamp =
  let decimals = json.getStr()
  if decimals == "":
    return none StorageTimestamp
  try:
    return some StorageTimestamp.init(StUint[40].fromDecimal(decimals))
  except ValueError:
    return none StorageTimestamp

proc decodeVersion1(_: type AvailabilityTerms, json: JsonNode): ?!AvailabilityTerms =
  without minimumPrice =? json{"minimumPricePerBytePerSecond"}.getUInt256():
    return failure "could not decode availability terms"
  without maximumCollateral =? json{"maximumCollateralPerByte"}.getUInt256():
    return failure "could not decode availability terms"
  without maximumDuration =? json{"maximumDuration"}.getUInt64():
    return failure "could not decode availability terms"
  var availableUntil: ?StorageTimestamp
  if value =? json{"availableUntil"}.getInt64():
    availableUntil = some StorageTimestamp.init(value.uint64.stuint(40))
  success AvailabilityTerms(
    minimumPricePerBytePerSecond: TokensPerSecond.init(minimumPrice.stuint(96)),
    maximumCollateralPerByte: Tokens.init(maximumCollateral.stuint(128)),
    maximumDuration: StorageDuration.init(maximumDuration.stuint(40)),
    availableUntil: availableUntil,
  )

proc decodeVersion2(_: type AvailabilityTerms, json: JsonNode): ?!AvailabilityTerms =
  without minimumPrice =? json{"minimumPricePerBytePerSecond"}.getTokensPerSecond():
    return failure "could not decode availability terms"
  without maximumCollateral =? json{"maximumCollateralPerByte"}.getTokens():
    return failure "could not decode availability terms"
  without maximumDuration =? json{"maximumDuration"}.getStorageDuration():
    return failure "could not decode availability terms"
  success AvailabilityTerms(
    minimumPricePerBytePerSecond: minimumPrice,
    maximumCollateralPerByte: maximumCollateral,
    maximumDuration: maximumDuration,
    availableUntil: json{"availableUntil"}.getStorageTimestamp(),
  )

proc decode*(_: type AvailabilityTerms, bytes: seq[byte]): ?!AvailabilityTerms =
  let json = ?catch parseJson(string.fromBytes(bytes))
  case json{"version"}.getInt()
  of 1:
    AvailabilityTerms.decodeVersion1(json)
  of 2:
    AvailabilityTerms.decodeVersion2(json)
  else:
    return failure "could not decode availability terms, unknown version"
