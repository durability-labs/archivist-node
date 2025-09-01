import std/json
import pkg/chronos/apps/http/httpclient
import pkg/stew/byteutils

type Http* = object

type HttpHeaders* = seq[(string, string)]

type
  HttpRequestOptions* = set[HttpRequestOption]
  HttpRequestOption* {.pure.} = enum
    checkStatusCode

type HttpResponse* = distinct HttpClientResponseRef

func status*(response: HttpResponse): int =
  HttpClientResponseRef(response).status

proc close*(response: HttpResponse) {.async.} =
  await noCancel HttpClientResponseRef(response).session.closeWait()

proc close*(response: Future[HttpResponse]) {.async.} =
  let response = await response
  await response.close()

proc read*(response: HttpResponse): Future[seq[byte]] {.async.} =
  let body  = await HttpClientResponseRef(response).getBodyBytes()
  await response.close()
  body

proc read*(response: Future[HttpResponse]): Future[seq[byte]] {.async.} =
  let response = await response
  await response.read()

proc readString*(response: HttpResponse): Future[string] {.async.} =
  string.fromBytes(await response.read())

proc readString*(response: Future[HttpResponse]): Future[string] {.async.} =
  let response = await response
  await response.readString()

proc readJson*(response: HttpResponse): Future[JsonNode] {.async.} =
  parseJson(await response.readString)

proc readJson*(response: Future[HttpResponse]): Future[JsonNode] {.async.} =
  let response = await response
  await response.readJson()

proc checkStatusCode*(response: HttpResponse) {.async.} =
  let status = response.status
  if status >= 200 and status < 300:
    return
  var message = "HTTP status code " & $status
  try:
    message &= ": " & await response.readString()
  except HttpError:
    discard
  raise newException(HttpError, message)

proc send(
  session: HttpSessionRef,
  request: HttpClientRequestRef,
  options: HttpRequestOptions
): Future[HttpResponse] {.async.} =
  var response: HttpResponse
  try:
    response = HttpResponse(await request.send())
  except HttpError as error:
    await noCancel session.closeWait()
    raise error

  if HttpRequestOption.checkStatusCode in options:
    await response.checkStatusCode()

  response

proc get*(
  _: type Http,
  url: string,
  headers: HttpHeaders = @{:},
  options: HttpRequestOptions = {HttpRequestOption.checkStatusCode}
): Future[HttpResponse] {.async.} =
  let session = HttpSessionRef.new()

  let request =
    HttpClientRequestRef
      .get(session, url, headers = headers)
      .tryGet()

  await session.send(request, options)

proc post*(
  _: type Http,
  url: string,
  body: seq[byte],
  headers: HttpHeaders = @{:},
  options: HttpRequestOptions = {HttpRequestOption.checkStatusCode}
): Future[HttpResponse] {.async.} =
  let session = HttpSessionRef.new()

  let request =
    HttpClientRequestRef
      .post(session, url, body = body, headers = headers)
      .tryGet()

  await session.send(request, options)

proc post*(
  _: type Http,
  url: string,
  body: JsonNode,
  headers: HttpHeaders = @{:},
  options: HttpRequestOptions = {HttpRequestOption.checkStatusCode}
): Future[HttpResponse] {.async.} =
  let headers = @{"Content-Type": "application/json"} & headers
  let body = ($body).toBytes
  await Http.post(url, body, headers, options)
