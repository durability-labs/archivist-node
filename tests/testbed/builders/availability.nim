import std/json
import pkg/chronos
import pkg/questionable
import ../network/node
import ../testbed
import ./api

type AvailabilityBuilder = ref object
  testbed: Testbed
  totalSize: ?int
  totalCollateral: ?int
  duration: ?uint64
  minPricePerBytePerSecond: ?int
  enabled: ?bool
  until: ?uint64

func availability*(testbed: Testbed): AvailabilityBuilder =
  AvailabilityBuilder(testbed: testbed)

func totalSize*(
  builder: AvailabilityBuilder,
  totalSize: int
): AvailabilityBuilder =
  builder.totalSize = some totalSize
  builder

func totalCollateral*(
  builder: AvailabilityBuilder,
  totalCollateral: int
): AvailabilityBuilder =
  builder.totalCollateral = some totalCollateral
  builder

func duration*(
  builder: AvailabilityBuilder,
  duration: uint64
): AvailabilityBuilder =
  builder.duration = some duration
  builder

func minPricePerBytePerSecond*(
  builder: AvailabilityBuilder,
  minPricePerBytePerSecond: int
): AvailabilityBuilder =
  builder.minPricePerBytePerSecond = some minPricePerBytePerSecond
  builder

func enabled*(builder: AvailabilityBuilder, enabled: bool): AvailabilityBuilder =
  builder.enabled = some enabled
  builder

func until*(builder: AvailabilityBuilder, timestamp: uint64): AvailabilityBuilder =
  builder.until = some timestamp
  builder

proc create*(builder: AvailabilityBuilder, node: Node): Future[JsonNode] {.async.} =
  let totalSize = builder.totalSize |? 1*1024*1024*1024
  let properties = %*{
    "totalSize": totalSize,
    "totalCollateral": builder.totalCollateral |? 5000 * totalSize,
    "duration": builder.duration |? 30*24*60*60,
    "minPricePerBytePerSecond": builder.minPricePerBytePerSecond |? 1
  }
  if enabled =? builder.enabled:
    properties["enabled"] = %enabled
  if until =? builder.until:
    properties["until"] = %until
  await builder.testbed.api(node).createAvailability(properties)

proc update*(builder: AvailabilityBuilder, node: Node, id: string) {.async.} =
  let properties = newJObject()
  if totalSize =? builder.totalSize:
    properties["totalSize"] = %totalSize
  if totalCollateral =? builder.totalCollateral:
    properties["totalCollateral"] = %totalCollateral
  if duration =? builder.duration:
    properties["duration"] = %duration
  if minPricePerBytePerSecond =? builder.minPricePerBytePerSecond:
    properties["minPricePerBytePerSecond"] = %minPricePerBytePerSecond
  if enabled =? builder.enabled:
    properties["enabled"] = %enabled
  if until =? builder.until:
    properties["until"] = %until
  await builder.testbed.api(node).updateAvailability(id, properties)
