import std/json
import std/strutils
import pkg/unittest2
import pkg/questionable
import pkg/questionable/results
import pkg/stint
import pkg/stew/byteutils
import archivist/marketplace/availability/terms
import archivist/marketplace/availability/encoding
import ./examples

suite "availability terms encoding":
  test "encodes with version 1":
    let terms = AvailabilityTerms.example
    let encoded = terms.encode()
    let json = parseJson(string.fromBytes(encoded))
    check json{"version"} == %1

  test "encodes price and collateral as decimals":
    let terms = AvailabilityTerms.example
    let encoded = terms.encode()
    let json = parseJson(string.fromBytes(encoded))
    check json{"minimumPricePerBytePerSecond"} == %($terms.minimumPricePerBytePerSecond)
    check json{"maximumCollateralPerByte"} == %($terms.maximumCollateralPerByte)

  test "encodes present availableUntil as integer":
    var terms = AvailabilityTerms.example
    terms.availableUntil = some SecondsSince1970.example
    let encoded = terms.encode()
    let json = parseJson(string.fromBytes(encoded))
    check json{"availableUntil"} == %terms.availableUntil

  test "encodes missing availableUntil as null":
    var terms = AvailabilityTerms.example
    terms.availableUntil = none SecondsSince1970
    let encoded = terms.encode()
    let json = parseJson(string.fromBytes(encoded))
    check json{"availableUntil"}.kind == JNull

  test "decodes encoded terms":
    let terms = AvailabilityTerms.example
    let encoded = terms.encode()
    check AvailabilityTerms.decode(encoded) == success terms

  test "decoding fails when version is not set":
    let terms = AvailabilityTerms.example
    let json = parseJson(string.fromBytes(terms.encode))
    json.delete("version")
    let encoded = ($json).toBytes
    let decoded = AvailabilityTerms.decode(encoded)
    check decoded.isFailure
    check "unknown version" in decoded.error.msg

  test "decoding fails when version is not 1":
    let terms = AvailabilityTerms.example
    let json = parseJson(string.fromBytes(terms.encode))
    for version in [%0, %2, %(-1), %int.low, %int.high, %"invalid", newJNull()]:
      json["version"] = version
      let encoded = ($json).toBytes
      let decoded = AvailabilityTerms.decode(encoded)
      check decoded.isFailure
      check "unknown version" in decoded.error.msg

  test "decoding fails when price or collateral is absent":
    let terms = AvailabilityTerms.example
    let json = parseJson(string.fromBytes(terms.encode))
    for property in ["minimumPricePerBytePerSecond", "maximumCollateralPerByte"]:
      json.delete(property)
      let encoded = ($json).toBytes
      let decoded = AvailabilityTerms.decode(encoded)
      check decoded.isFailure
      check "could not decode" in decoded.error.msg

  test "decoding fails when price or collateral is not a decimal string":
    let terms = AvailabilityTerms.example
    let json = parseJson(string.fromBytes(terms.encode))
    for property in ["minimumPricePerBytePerSecond", "maximumCollateralPerByte"]:
      for value in [newJNull(), %"", %"123ab", %123]:
        json[property] = value
        let encoded = ($json).toBytes
        let decoded = AvailabilityTerms.decode(encoded)
        check decoded.isFailure
        check "could not decode" in decoded.error.msg
