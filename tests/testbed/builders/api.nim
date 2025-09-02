import std/json
import pkg/chronos
import pkg/questionable
import ../testbed
import ../network/node
import ../helpers/http

type ApiBuilder = ref object
  testbed: Testbed
  url: string

func api*(testbed: Testbed, node: Node): ApiBuilder =
  ApiBuilder(testbed: testbed, url: node.apiUrl)

proc getSpr*(builder: ApiBuilder): Future[?string] {.async.} =
  let info = await Http.get(builder.url & "/debug/info").readJson()
  if spr =? info{"spr"}:
    some spr.getStr()
  else:
    none string

proc getPurchase*(builder: ApiBuilder, id: string): Future[JsonNode] {.async.} =
  await Http.get(builder.url & "/storage/purchases/" & id).readJson()

proc getAvailability*(builder: ApiBuilder): Future[JsonNode] {.async.} =
  await Http.get(builder.url & "/sales/availability").readJson()
