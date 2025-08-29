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

proc create*(builder: AvailabilityBuilder, node: Node) {.async.} =
  let totalSize = builder.totalSize |? 1*1024*1024*1024
  let url = node.apiUrl & "/sales/availability"
  let body = %*{
    "totalSize": totalSize,
    "totalCollateral": builder.totalCollateral |? 100 * totalSize,
    "duration": builder.duration |? 30*24*60*60,
    "minPricePerBytePerSecond": builder.minPricePerBytePerSecond |? 1
  }
  await Http.post(url, body).close()
