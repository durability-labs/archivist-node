import std/json
import pkg/chronos
import pkg/questionable
import ../network/node
import ../helpers/http
import ../testbed

type AvailabilityBuilder = ref object
  testbed: Testbed
  totalSize: ?int
  totalCollateral: ?int
  duration: ?int
  minPricePerBytePerSecond: ?int
  enabled: ?bool
  until: ?int

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
  duration: int
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

func until*(builder: AvailabilityBuilder, timestamp: int): AvailabilityBuilder =
  builder.until = some timestamp
  builder

proc create*(builder: AvailabilityBuilder, node: Node): Future[JsonNode] {.async.} =
  let totalSize = builder.totalSize |? 1*1024*1024*1024
  let url = node.apiUrl & "/sales/availability"
  let body = %*{
    "totalSize": totalSize,
    "totalCollateral": builder.totalCollateral |? 5000 * totalSize,
    "duration": builder.duration |? 30*24*60*60,
    "minPricePerBytePerSecond": builder.minPricePerBytePerSecond |? 1
  }
  if enabled =? builder.enabled:
    body["enabled"] = %enabled
  if until =? builder.until:
    body["until"] = %until
  await Http.post(url, body).readJson()

proc update*(builder: AvailabilityBuilder, node: Node, id: string) {.async.} =
  let url = node.apiUrl & "/sales/availability/" & id
  let body = newJObject()
  if totalSize =? builder.totalSize:
    body["totalSize"] = %totalSize
  if totalCollateral =? builder.totalCollateral:
    body["totalCollateral"] = %totalCollateral
  if duration =? builder.duration:
    body["duration"] = %duration
  if minPricePerBytePerSecond =? builder.minPricePerBytePerSecond:
    body["minPricePerBytePerSecond"] = %minPricePerBytePerSecond
  if enabled =? builder.enabled:
    body["enabled"] = %enabled
  if until =? builder.until:
    body["until"] = %until
  discard await Http.patch(url, body)
