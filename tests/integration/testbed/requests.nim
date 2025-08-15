import pkg/chronos
import pkg/questionable
import pkg/stint
import ./testbed
# import ./upload

type RequestBuilder = ref object
  testbed: Testbed
  expiry: ?uint64
  duration: ?uint64
  proofProbability: ?UInt256
  collateralPerByte: ?UInt256
  pricePerBytePerSecond: ?UInt256
  nodes: ?uint
  tolerance: ?uint

func request*(testbed: Testbed): RequestBuilder =
  RequestBuilder(testbed: testbed)

proc start*(builder: RequestBuilder) {.async.} =
  let expiry = builder.expiry |? 600
  let duration = builder.duration |? 3600
  let proofProbability = builder.proofProbability |? 1.u256
  let collateralPerByte = builder.collateralPerByte |? 1.u256
  let pricePerBytePerSecond = builder.pricePerBytePerSecond |? 1.u256
  let nodes = builder.nodes |? 5
  let tolerance = builder.tolerance |? 2
  # TODO: client