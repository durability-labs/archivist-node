import std/json
import std/options
import pkg/questionable
import pkg/questionable/results
import pkg/stew/byteutils
import pkg/stint
import ./terms

{.push raises: [].}

func encode*(terms: AvailabilityTerms): seq[byte] =
  let json =
    %*{
      "version": 1,
      "minimumPricePerBytePerSecond": $terms.minimumPricePerBytePerSecond,
      "maximumCollateralPerByte": $terms.maximumCollateralPerByte,
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

proc decodeVersion1(_: type AvailabilityTerms, json: JsonNode): ?!AvailabilityTerms =
  without minimumPrice =? json{"minimumPricePerBytePerSecond"}.getUInt256():
    return failure "could not decode availability terms"
  without maximumCollateral =? json{"maximumCollateralPerByte"}.getUInt256():
    return failure "could not decode availability terms"
  success AvailabilityTerms(
    minimumPricePerBytePerSecond: minimumPrice,
    maximumCollateralPerByte: maximumCollateral,
    availableUntil: json{"availableUntil"}.getInt64(),
  )

proc decode*(_: type AvailabilityTerms, bytes: seq[byte]): ?!AvailabilityTerms =
  let json = ?catch parseJson(string.fromBytes(bytes))
  case json{"version"}.getInt()
  of 1:
    AvailabilityTerms.decodeVersion1(json)
  else:
    return failure "could not decode availability terms, unknown version"
