import std/json
import pkg/chronos
import pkg/ethers
import pkg/questionable
import ../testbed
import ../network/node
import ../helpers/http

export http.HttpError
export http.HttpResponse
export http.HttpHeaders
export http.headers
export http.read
export http.close

type ApiBuilder = ref object
  url: string

type RawBuilder = ref object
  url: string

func api*(testbed: Testbed, node: Node): ApiBuilder =
  ApiBuilder(url: node.apiUrl)

func raw*(builder: ApiBuilder): RawBuilder =
  RawBuilder(url: builder.url)

proc getDebugInfo*(builder: RawBuilder): Future[HttpResponse] {.async.} =
  await Http.get(builder.url & "/debug/info")

proc getDebugInfo*(builder: ApiBuilder): Future[JsonNode] {.async.} =
  await builder.raw.getDebugInfo().readJson()

proc setSystemTestingOption*(
    builder: ApiBuilder, key: string, value: string
): Future[void] {.async.} =
  discard await Http.post(builder.url & "/debug/testing/option/" & key & "/" & value)

proc setSimulateProofFailures*(builder: ApiBuilder, proofFailures: int) {.async.} =
  await builder.setSystemTestingOption("simulate_proof_failures", $proofFailures)

proc getSpr*(builder: ApiBuilder): Future[?string] {.async.} =
  let info = await builder.getDebugInfo()
  if spr =? info{"spr"}:
    some spr.getStr()
  else:
    none string

proc getEthAddress*(builder: ApiBuilder): Future[?Address] {.async.} =
  let info = await builder.getDebugInfo()
  if address =? info{"ethAddress"}:
    Address.init(address.getStr())
  else:
    none Address

proc getSpace*(builder: RawBuilder): Future[HttpResponse] {.async.} =
  await Http.get(builder.url & "/space")

proc getSpace*(builder: ApiBuilder): Future[JsonNode] {.async.} =
  await builder.raw.getSpace().readJson()

proc getData*(builder: RawBuilder): Future[HttpResponse] {.async.} =
  await Http.get(builder.url & "/data")

proc getData*(builder: ApiBuilder): Future[JsonNode] {.async.} =
  await builder.raw.getData().readJson()

proc getPurchase*(builder: RawBuilder, id: string): Future[HttpResponse] {.async.} =
  await Http.get(builder.url & "/storage/purchases/" & id)

proc getPurchase*(builder: ApiBuilder, id: string): Future[JsonNode] {.async.} =
  await builder.raw.getPurchase(id).readJson()

proc updateAvailability*(builder: ApiBuilder, properties: JsonNode) {.async.} =
  await Http.post(builder.url & "/sales/availability", properties).close()

proc getAvailability*(builder: RawBuilder): Future[HttpResponse] {.async.} =
  await Http.get(builder.url & "/sales/availability")

proc getAvailability*(builder: ApiBuilder): Future[JsonNode] {.async.} =
  await builder.raw.getAvailability().readJson()

proc getSlots*(builder: RawBuilder): Future[HttpResponse] {.async.} =
  await Http.get(builder.url & "/sales/slots")

proc getSlots*(builder: ApiBuilder): Future[JsonNode] {.async.} =
  await builder.raw.getSlots().readJson()

proc upload*(
    builder: RawBuilder,
    data: seq[byte],
    mimetype = string.none,
    filename = string.none,
    headers: HttpHeaders = @{:},
): Future[HttpResponse] {.async.} =
  var headers = headers
  if mimetype =? mimetype:
    headers.add(("Content-Type", mimetype))
  if filename =? filename:
    let disposition = "attachment; filename=\"" & filename & "\""
    headers.add(("Content-Disposition", disposition))
  await Http.post(builder.url & "/data", data, headers = headers)

proc upload*(
    builder: ApiBuilder,
    data: seq[byte],
    mimetype = string.none,
    filename = string.none,
    headers: HttpHeaders = @{:},
): Future[string] {.async.} =
  await builder.raw.upload(data, mimetype, filename, headers).readString()

proc download*(
    builder: RawBuilder, cid: string, network: bool = true
): Future[HttpResponse] {.async.} =
  var url = builder.url & "/data/" & cid
  if network:
    url &= "/network/stream"
  await Http.get(url)

proc download*(
    builder: ApiBuilder, cid: string, network: bool = true
): Future[seq[byte]] {.async.} =
  await builder.raw.download(cid, network).read()

proc downloadManifest*(
    builder: RawBuilder, cid: string
): Future[HttpResponse] {.async.} =
  await Http.get(builder.url & "/data/" & cid & "/network/manifest")

proc downloadManifest*(builder: ApiBuilder, cid: string): Future[JsonNode] {.async.} =
  await builder.raw.downloadManifest(cid).readJson()

proc downloadInBackground*(
    builder: RawBuilder, cid: string
): Future[HttpResponse] {.async.} =
  await Http.post(builder.url & "/data/" & cid & "/network")

proc downloadInBackground*(
    builder: ApiBuilder, cid: string
): Future[JsonNode] {.async.} =
  await builder.raw.downloadInBackground(cid).readJson()

proc delete*(builder: ApiBuilder, cid: string) {.async.} =
  await Http.delete(builder.url & "/data/" & cid).close()

proc setLogLevel*(builder: ApiBuilder, level: string) {.async.} =
  await Http.post(builder.url & "/debug/chronicles/loglevel?level=" & level).close()

proc status*(builder: RawBuilder, cid: string): Future[HttpResponse] {.async.} =
  var url = builder.url & "/data/" & cid & "/status"
  await Http.get(url)

proc status*(builder: ApiBuilder, cid: string): Future[JsonNode] {.async.} =
  await builder.raw.status(cid).readJson()
