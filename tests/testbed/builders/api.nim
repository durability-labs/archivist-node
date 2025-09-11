import std/json
import pkg/chronos
import pkg/ethers
import pkg/questionable
import ../testbed
import ../network/node
import ../helpers/http

export http.HttpError

type ApiBuilder = ref object
  testbed: Testbed
  url: string

func api*(testbed: Testbed, node: Node): ApiBuilder =
  ApiBuilder(testbed: testbed, url: node.apiUrl)

proc getInfo(builder: ApiBuilder): Future[JsonNode] {.async.} =
  await Http.get(builder.url & "/debug/info").readJson()

proc getSpr*(builder: ApiBuilder): Future[?string] {.async.} =
  let info = await builder.getInfo()
  if spr =? info{"spr"}:
    some spr.getStr()
  else:
    none string

proc getEthAddress*(builder: ApiBuilder): Future[?Address] {.async.} =
  let info = await builder.getInfo()
  if address =? info{"ethAddress"}:
    Address.init(address.getStr())
  else:
    none Address

proc getPurchase*(builder: ApiBuilder, id: string): Future[JsonNode] {.async.} =
  await Http.get(builder.url & "/storage/purchases/" & id).readJson()

proc getAvailability*(builder: ApiBuilder): Future[JsonNode] {.async.} =
  await Http.get(builder.url & "/sales/availability").readJson()

proc upload*(builder: ApiBuilder, data: seq[byte]): Future[string] {.async.} =
  await Http.post(builder.url & "/data", data).readString()

proc download*(
  builder: ApiBuilder,
  cid: string,
  network: bool = true
): Future[seq[byte]] {.async.} =
  var url = builder.url & "/data/" & cid
  if network:
    url &= "/network/stream"
  await Http.get(url).read()

proc downloadManifest*(
  builder: ApiBuilder,
  cid: string
): Future[JsonNode] {.async.} =
  await Http.get(builder.url & "/data/" & cid & "/network/manifest").readJson()

proc downloadInBackground*(
  builder: ApiBuilder,
  cid: string
): Future[JsonNode] {.async.} =
  await Http.post(builder.url & "/data/" & cid & "/network").readJson()
