import std/json
import pkg/chronos
import pkg/ethers
import pkg/questionable
import ../testbed
import ../network/node
import ../helpers/http

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
