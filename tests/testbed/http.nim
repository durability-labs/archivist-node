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

  var response: HttpResponse
  try:
    response = HttpResponse(await request.send())
  except HttpError as error:
    await noCancel session.closeWait()
    raise error

  if HttpRequestOption.checkStatusCode in options:
    if response.status < 200 or response.status >= 300:
      raise newException(HttpError, "HTTP status code: " & $response.status)

  response

proc close*(response: HttpResponse) {.async.} =
  await noCancel HttpClientResponseRef(response).session.closeWait()

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
