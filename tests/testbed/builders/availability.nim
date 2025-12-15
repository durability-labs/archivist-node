import std/json
import pkg/chronos
import pkg/questionable
import ../network/node
import ../testbed
import ./api

type AvailabilityBuilder = ref object
  testbed: Testbed
  maximumCollateralPerByte: ?int
  maximumDuration: ?uint64
  minimumPricePerBytePerSecond: ?int
  availableUntil: ?uint64

func availability*(testbed: Testbed): AvailabilityBuilder =
  AvailabilityBuilder(testbed: testbed)

func maximumCollateralPerByte*(
    builder: AvailabilityBuilder, collateral: int
): AvailabilityBuilder =
  builder.maximumCollateralPerByte = some collateral
  builder

func maximumDuration*(
    builder: AvailabilityBuilder, duration: uint64
): AvailabilityBuilder =
  builder.maximumDuration = some duration
  builder

func minimumPricePerBytePerSecond*(
    builder: AvailabilityBuilder, price: int
): AvailabilityBuilder =
  builder.minimumPricePerBytePerSecond = some price
  builder

func availableUntil*(
    builder: AvailabilityBuilder, timestamp: uint64
): AvailabilityBuilder =
  builder.availableUntil = some timestamp
  builder

proc update*(builder: AvailabilityBuilder, node: Node) {.async.} =
  let properties =
    %*{
      "maximumCollateralPerByte": builder.maximumCollateralPerByte |? 5000,
      "maximumDuration": builder.maximumDuration |? 30 * 24 * 60 * 60,
      "minimumPricePerBytePerSecond": builder.minimumPricePerBytePerSecond |? 1,
    }
  if availableUntil =? builder.availableUntil:
    properties["availableUntil"] = %availableUntil
  await builder.testbed.api(node).updateAvailability(properties)
