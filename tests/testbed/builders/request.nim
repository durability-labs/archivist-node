import std/json
import pkg/chronos
import pkg/questionable
import ../network/node
import ../helpers/http
import ../testbed
import ../dataset
import ../request
import ../error
import ./dataset
import ./marketplace

type RequestBuilder = ref object
  testbed: Testbed
  dataset: ?Dataset
  duration: ?int
  proofProbability: ?int
  pricePerBytePerSecond: ?int
  expiry: ?int
  nodes: ?int
  tolerance: ?int
  collateralPerByte: ?int

func request*(testbed: Testbed): RequestBuilder =
  RequestBuilder(testbed: testbed)

func dataset*(builder: RequestBuilder, dataset: Dataset): RequestBuilder =
  builder.dataset = some dataset
  builder

func duration*(builder: RequestBuilder, duration: int): RequestBuilder =
  builder.duration = some duration
  builder

func proofProbability*(
  builder: RequestBuilder,
  proofProbability: int
): RequestBuilder =
  builder.proofProbability = some proofProbability
  builder

func pricePerBytePerSecond*(
  builder: RequestBuilder,
  pricePerBytePerSecond: int
): RequestBuilder =
  builder.pricePerBytePerSecond = some pricePerBytePerSecond
  builder

func expiry*(builder: RequestBuilder, expiry: int): RequestBuilder =
  builder.expiry = some expiry
  builder

func nodes*(builder: RequestBuilder, nodes: int): RequestBuilder =
  builder.nodes = some nodes
  builder

func tolerance*(builder: RequestBuilder, tolerance: int): RequestBuilder =
  builder.tolerance = some tolerance
  builder

func collateralPerByte*(
  builder: RequestBuilder,
  collateralPerByte: int
): RequestBuilder =
  builder.collateralPerByte = some collateralPerByte
  builder

proc submit*(builder: RequestBuilder, requester: Node): Future[Request] {.async.} =
  let dataset = builder.dataset |? await builder.testbed.dataset.upload(requester)
  without cid =? dataset.cid:
    raise newException(TestbedError, "missing cid, did you upload the dataset?")
  let url = requester.apiUrl & "/storage/request/" & cid
  let duration = builder.duration |? 60 * 60
  let expiry = builder.expiry |? 10 * 60
  let body = %*{
    "cid": cid,
    "duration": duration,
    "proofProbability": builder.proofProbability |? 1,
    "collateralPerByte": builder.collateralPerByte |? 1000,
    "pricePerBytePerSecond": builder.pricePerBytePerSecond |? 10,
    "expiry": expiry,
    "nodes": builder.nodes |? 3,
    "tolerance": builder.tolerance |? 1,
  }
  let requestId = await Http.post(url, body).readString()
  Request.init(dataset, requestId, duration, expiry)

proc start*(builder: RequestBuilder, requester: Node): Future[Request] {.async.} =
  let request = await builder.submit(requester)
  let requestId = request.id
  await builder.testbed.marketplace.waitForRequestStarted(requestId)
  request
