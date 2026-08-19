## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/sequtils
import std/mimetypes
import std/os

import pkg/questionable
import pkg/questionable/results
import pkg/chronos
import pkg/presto except toJson
import pkg/metrics except toJson
import pkg/stew/base10
import pkg/stew/byteutils
import pkg/confutils
import pkg/stint

import pkg/libp2p
import pkg/libp2p/routing_record
import pkg/kvstore
import pkg/archivistdht/discv5/spr as spr

import ../logutils
import ../node
import ../blocktype
import ../conf
import ../erasure/erasure
import ../manifest
import ../streams/asyncstreamwrapper
import ../stores
import ../marketplace

import ./coders
import ./json

logScope:
  topics = "archivist restapi"

declareCounter(archivist_api_uploads, "archivist API uploads")
declareCounter(archivist_api_downloads, "archivist API downloads")

const DefaultStreamBatch* = 128 # Number of blocks to fetch per stream read

proc validate(pattern: string, value: string): int {.gcsafe, raises: [Defect].} =
  0

proc formatManifest(cid: Cid, manifest: Manifest): RestContent =
  return RestContent.init(cid, manifest)

proc formatManifestBlocks(node: ArchivistNodeRef): Future[JsonNode] {.async.} =
  var content: seq[RestContent]

  proc addManifest(cid: Cid, manifest: Manifest) =
    content.add(formatManifest(cid, manifest))

  await node.iterateManifests(addManifest)

  return %RestContentList.init(content)

proc formatDatasetStatus(
    node: ArchivistNodeRef, repostore: RepoStore, cid: Cid
): Future[?!JsonNode] {.async.} =
  without manifest =? (await node.fetchManifest(cid)), err:
    error "Failed to fetch manifest", err = err.msg
    return failure(err)

  without overlay =? (await repostore.getOverlay(manifest.treeCid)), err:
    error "Failed to fetch overlay", err = err.msg
    return failure(err)

  let allIndices = toSeq(0.Natural ..< manifest.blocksCount.Natural)
  without hasBlocks =? (await repostore.hasBlocks(manifest.treeCid, allIndices)), err:
    error "Failed to run hasBlocks", err = err.msg
    return failure(err)

  return success(%RestDatasetStatus.init(cid, overlay, hasBlocks))

proc isPending(resp: HttpResponseRef): bool =
  ## Checks that an HttpResponseRef object is still pending; i.e.,
  ## that no body has yet been sent. This helps us guard against calling
  ## sendBody(resp: HttpResponseRef, ...) twice, which is illegal.
  return resp.getResponseState() == HttpResponseState.Empty

proc retrieveCid(
    node: ArchivistNodeRef, cid: Cid, local: bool = true, resp: HttpResponseRef
): Future[void] {.async: (raises: [CancelledError, HttpWriteError]).} =
  ## Download a file from the node in a streaming
  ## manner
  ##

  var lpStream: LPStream

  var bytes = 0
  try:
    without stream =? (await node.retrieve(cid, local)), error:
      if error of BlockNotFoundError:
        resp.status = Http404
        await resp.sendBody(
          "The requested CID could not be retrieved (" & error.msg & ")."
        )
        return
      else:
        resp.status = Http500
        await resp.sendBody(error.msg)
        return

    lpStream = stream

    # It is ok to fetch again the manifest because it will hit the cache
    without manifest =? (await node.fetchManifest(cid)), err:
      error "Failed to fetch manifest", err = err.msg
      resp.status = Http404
      await resp.sendBody(err.msg)
      return

    if manifest.mimetype.isSome:
      resp.setHeader("Content-Type", manifest.mimetype.get())
    else:
      resp.addHeader("Content-Type", "application/octet-stream")

    if manifest.filename.isSome:
      resp.setHeader(
        "Content-Disposition",
        "attachment; filename=\"" & manifest.filename.get() & "\"",
      )
    else:
      resp.setHeader("Content-Disposition", "attachment")

    # For erasure-coded datasets, we need to return the _original_ length; i.e.,
    # the length of the non-erasure-coded dataset, as that's what we will be
    # returning to the client.
    let contentLength =
      if manifest.protected: manifest.originalDatasetSize else: manifest.datasetSize
    resp.setHeader("Content-Length", $(contentLength.int))

    await resp.prepare(HttpResponseStreamType.Plain)

    while not stream.atEof:
      var
        buff = newSeqUninitialized[byte](DefaultStreamBatch * DefaultBlockSize.int)
        len = await stream.readOnce(addr buff[0], buff.len)

      buff.setLen(len)
      if buff.len <= 0:
        break

      bytes += buff.len

      await resp.send(addr buff[0], buff.len)

    if bytes != contentLength.int:
      # The response would end short of the declared Content-Length. Abort
      # without finishing so the client sees the truncation loudly instead of
      # a clean short body.
      error "Response body shorter than declared",
        cid = cid, bytes, declared = contentLength.int
      return

    await resp.finish()
    archivist_api_downloads.inc()
  except CancelledError as exc:
    raise exc
  except LPStreamError as exc:
    warn "Error streaming blocks", exc = exc.msg
    if resp.isPending():
      resp.status = Http500
      await resp.sendBody(exc.msg)
    else:
      # The response already started - abort so the client sees the truncation
      # loudly instead of a clean short body.
      error "Response aborted mid-stream", cid = cid, bytes, error = exc.msg
  finally:
    info "Sent bytes", cid = cid, bytes
    if not lpStream.isNil:
      await lpStream.close()

proc buildCorsHeaders(
    httpMethod: string, allowedOrigin: Option[string]
): seq[(string, string)] =
  var headers: seq[(string, string)] = newSeq[(string, string)]()

  if corsOrigin =? allowedOrigin:
    headers.add(("Access-Control-Allow-Origin", corsOrigin))
    headers.add(("Access-Control-Allow-Methods", httpMethod & ", OPTIONS"))
    headers.add(("Access-Control-Max-Age", "86400"))

  return headers

proc setCorsHeaders(resp: HttpResponseRef, httpMethod: string, origin: string) =
  resp.setHeader("Access-Control-Allow-Origin", origin)
  resp.setHeader("Access-Control-Allow-Methods", httpMethod & ", OPTIONS")
  resp.setHeader("Access-Control-Max-Age", "86400")

proc getFilenameFromContentDisposition(contentDisposition: string): ?string =
  if not ("filename=" in contentDisposition):
    return string.none

  let parts = contentDisposition.split("filename=\"")

  if parts.len < 2:
    return string.none

  let filename = parts[1].strip()
  return filename[0 ..^ 2].some

proc initDataApi(node: ArchivistNodeRef, repoStore: RepoStore, router: var RestRouter) =
  let allowedOrigin = router.allowedOrigin # prevents capture inside of api defintion

  router.api(MethodOptions, "/api/archivist/v1/data") do(
    resp: HttpResponseRef
  ) -> RestApiResponse:
    if corsOrigin =? allowedOrigin:
      resp.setCorsHeaders("POST", corsOrigin)
      resp.setHeader(
        "Access-Control-Allow-Headers", "content-type, content-disposition"
      )

    resp.status = Http204
    await resp.sendBody("")

  router.rawApi(MethodPost, "/api/archivist/v1/data") do() -> RestApiResponse:
    ## Upload a file in a streaming manner
    ##

    trace "Handling file upload"
    var bodyReader = request.getBodyReader()
    if bodyReader.isErr():
      return RestApiResponse.error(Http500, msg = bodyReader.error())

    # Attempt to handle `Expect` header
    # some clients (curl), wait 1000ms
    # before giving up
    #
    await request.handleExpect()

    var mimetype = request.headers.getString(ContentTypeHeader).some

    if mimetype.get() != "":
      let mimetypeVal = mimetype.get()
      var m = newMimetypes()
      let extension = m.getExt(mimetypeVal, "")
      if extension == "":
        return RestApiResponse.error(
          Http422, "The MIME type '" & mimetypeVal & "' is not valid."
        )
    else:
      mimetype = string.none

    const ContentDispositionHeader = "Content-Disposition"
    let contentDisposition = request.headers.getString(ContentDispositionHeader)
    let filename = getFilenameFromContentDisposition(contentDisposition)

    if filename.isSome and not isValidFilename(filename.get()):
      return RestApiResponse.error(Http422, "The filename is not valid.")

    # Here we could check if the extension matches the filename if needed

    let reader = bodyReader.get()

    try:
      without cid =? (
        await node.store(
          AsyncStreamWrapper.new(reader = AsyncStreamReader(reader)),
          filename = filename,
          mimetype = mimetype,
        )
      ), error:
        if error of QuotaNotEnoughError:
          return RestApiResponse.error(Http413, error.msg)
        if error of KVConflictError:
          return RestApiResponse.error(Http409, error.msg)
        error "Error uploading file", exc = error.msg
        return RestApiResponse.error(Http500, error.msg)

      archivist_api_uploads.inc()
      trace "Uploaded file", cid
      return RestApiResponse.response($cid)
    except CancelledError:
      trace "Upload cancelled error"
      return RestApiResponse.error(Http500)
    except AsyncStreamError:
      trace "Async stream error"
      return RestApiResponse.error(Http500)
    finally:
      await reader.closeWait()

  router.api(MethodGet, "/api/archivist/v1/data") do() -> RestApiResponse:
    let json = await formatManifestBlocks(node)
    return RestApiResponse.response($json, contentType = "application/json")

  router.api(MethodGet, "/api/archivist/v1/data/{cid}/status") do(
    cid: Cid, resp: HttpResponseRef
  ) -> RestApiResponse:
    if cid.isErr:
      return RestApiResponse.error(Http400, $cid.error())

    without json =? (await formatDatasetStatus(node, repostore, cid.get())), err:
      error "Failed create RestDatasetStatus object", err = err.msg
      return RestApiResponse.error(Http404, err.msg)

    return RestApiResponse.response($json, contentType = "application/json")

  router.api(MethodOptions, "/api/archivist/v1/data/{cid}") do(
    cid: Cid, resp: HttpResponseRef
  ) -> RestApiResponse:
    if corsOrigin =? allowedOrigin:
      resp.setCorsHeaders("GET,DELETE", corsOrigin)

    resp.status = Http204
    await resp.sendBody("")

  router.api(MethodGet, "/api/archivist/v1/data/{cid}") do(
    cid: Cid, resp: HttpResponseRef
  ) -> RestApiResponse:
    var headers = buildCorsHeaders("GET", allowedOrigin)

    ## Download a file from the local node in a streaming
    ## manner
    if cid.isErr:
      return RestApiResponse.error(Http400, $cid.error(), headers = headers)

    if corsOrigin =? allowedOrigin:
      resp.setCorsHeaders("GET", corsOrigin)
      resp.setHeader("Access-Control-Headers", "X-Requested-With")

    await node.retrieveCid(cid.get(), local = true, resp = resp)

  router.api(MethodDelete, "/api/archivist/v1/data/{cid}") do(
    cid: Cid, resp: HttpResponseRef
  ) -> RestApiResponse:
    ## Deletes either a single block or an entire dataset
    ## from the local node. Returns 404 if the dataset
    ## is not locally available.
    ##
    var headers = buildCorsHeaders("DELETE", allowedOrigin)

    if cid.isErr:
      return RestApiResponse.error(Http400, $cid.error(), headers = headers)

    if err =? (await node.delete(cid.get())).errorOption:
      if err of BlockNotFoundError:
        return RestApiResponse.error(Http404, err.msg, headers = headers)
      return RestApiResponse.error(Http500, err.msg, headers = headers)

    if corsOrigin =? allowedOrigin:
      resp.setCorsHeaders("DELETE", corsOrigin)

    resp.status = Http204
    await resp.sendBody("")

  router.api(MethodPost, "/api/archivist/v1/data/{cid}/network") do(
    cid: Cid, resp: HttpResponseRef
  ) -> RestApiResponse:
    ## Download a file from the network to the local node
    ##

    var headers = buildCorsHeaders("GET", allowedOrigin)

    if cid.isErr:
      return RestApiResponse.error(Http400, $cid.error(), headers = headers)

    without manifest =? (await node.fetchManifest(cid.get())), err:
      error "Failed to fetch manifest", err = err.msg
      return RestApiResponse.error(Http404, err.msg, headers = headers)

    # Start fetching the dataset in the background
    node.fetchDatasetAsyncTask(manifest)

    let json = %formatManifest(cid.get(), manifest)
    return RestApiResponse.response($json, contentType = "application/json")

  router.api(MethodGet, "/api/archivist/v1/data/{cid}/network/stream") do(
    cid: Cid, resp: HttpResponseRef
  ) -> RestApiResponse:
    ## Download a file from the network in a streaming
    ## manner
    ##

    var headers = buildCorsHeaders("GET", allowedOrigin)

    if cid.isErr:
      return RestApiResponse.error(Http400, $cid.error(), headers = headers)

    if corsOrigin =? allowedOrigin:
      resp.setCorsHeaders("GET", corsOrigin)
      resp.setHeader("Access-Control-Headers", "X-Requested-With")

    resp.setHeader("Access-Control-Expose-Headers", "Content-Disposition")
    await node.retrieveCid(cid.get(), local = false, resp = resp)

  router.api(MethodGet, "/api/archivist/v1/data/{cid}/network/manifest") do(
    cid: Cid, resp: HttpResponseRef
  ) -> RestApiResponse:
    ## Download only the manifest.
    ##

    var headers = buildCorsHeaders("GET", allowedOrigin)

    if cid.isErr:
      return RestApiResponse.error(Http400, $cid.error(), headers = headers)

    without manifest =? (await node.fetchManifest(cid.get())), err:
      error "Failed to fetch manifest", err = err.msg
      return RestApiResponse.error(Http404, err.msg, headers = headers)

    let json = %formatManifest(cid.get(), manifest)
    return RestApiResponse.response($json, contentType = "application/json")

  router.api(MethodGet, "/api/archivist/v1/space") do() -> RestApiResponse:
    let json =
      %RestRepoStore(
        totalBlocks: repoStore.totalBlocks,
        quotaMaxBytes: repoStore.quotaMaxBytes,
        quotaUsedBytes: repoStore.quotaUsedBytes,
        quotaReservedBytes: repoStore.quotaReservedBytes,
      )
    return RestApiResponse.response($json, contentType = "application/json")

proc initSalesApi(node: ArchivistNodeRef, router: var RestRouter) =
  let allowedOrigin = router.allowedOrigin

  router.api(MethodGet, "/api/archivist/v1/sales/slots") do() -> RestApiResponse:
    var headers = buildCorsHeaders("GET", allowedOrigin)

    ## Returns active slots for the host
    try:
      without marketplace =? node.marketplace:
        return RestApiResponse.error(
          Http503, "Persistence is not enabled", headers = headers
        )

      let json = %(await marketplace.sales.getSlots())
      return RestApiResponse.response(
        $json, contentType = "application/json", headers = headers
      )
    except CatchableError as exc:
      trace "Excepting processing request", exc = exc.msg
      return RestApiResponse.error(Http500, headers = headers)

  router.api(MethodGet, "/api/archivist/v1/sales/slots/{slotId}") do(
    slotId: SlotId
  ) -> RestApiResponse:
    ## Returns active slot with id {slotId} for the host. Returns 404 if the
    ## slot is not active for the host.
    var headers = buildCorsHeaders("GET", allowedOrigin)

    without marketplace =? node.marketplace:
      return
        RestApiResponse.error(Http503, "Persistence is not enabled", headers = headers)

    without slotId =? slotId.tryGet.catch, error:
      return RestApiResponse.error(Http400, error.msg, headers = headers)

    without slot =? await marketplace.sales.getSlot(slotId):
      return
        RestApiResponse.error(Http404, "Provider not filling slot", headers = headers)

    let restSalesSlot = RestSalesSlot(
      state: slot.state |? "none",
      slotIndex: slot.slotIndex,
      requestId: slot.requestId,
      request: slot.request,
    )

    return RestApiResponse.response(
      restSalesSlot.toJson, contentType = "application/json", headers = headers
    )

  router.api(MethodGet, "/api/archivist/v1/sales/availability") do() -> RestApiResponse:
    ## Returns storage that is for sale
    var headers = buildCorsHeaders("GET", allowedOrigin)

    try:
      without marketplace =? node.marketplace:
        return RestApiResponse.error(
          Http503, "Persistence is not enabled", headers = headers
        )

      without availability =? marketplace.sales.availability:
        return RestApiResponse.error(Http404, "not found", headers = headers)

      let json =
        %*{
          "minimumPricePerBytePerSecond": availability.minimumPricePerBytePerSecond,
          "maximumCollateralPerByte": availability.maximumCollateralPerByte,
          "maximumDuration": availability.maximumDuration,
          "availableUntil": availability.availableUntil,
        }
      return RestApiResponse.response(
        $json, contentType = "application/json", headers = headers
      )
    except CatchableError as exc:
      trace "Excepting processing request", exc = exc.msg
      return RestApiResponse.error(Http500, headers = headers)

  router.rawApi(MethodPost, "/api/archivist/v1/sales/availability") do() -> RestApiResponse:
    ## Sets availabilty; the terms under which the node will sell storage

    var headers = buildCorsHeaders("POST", allowedOrigin)

    try:
      without marketplace =? node.marketplace:
        return RestApiResponse.error(
          Http503, "Persistence is not enabled", headers = headers
        )

      let body = await request.getBody()

      without restAv =? RestAvailability.fromJson(body), error:
        return RestApiResponse.error(Http400, error.msg, headers = headers)

      if restAv.maximumDuration.u64 == 0:
        return RestApiResponse.error(
          Http422, "maximumDuration must be larger than zero", headers = headers
        )

      if restAv.minimumPricePerBytePerSecond.u256 == 0.u256:
        return RestApiResponse.error(
          Http422,
          "minimumPricePerBytePerSecond must be larger than zero",
          headers = headers,
        )

      if restAv.maximumCollateralPerByte.u256 == 0.u256:
        return RestApiResponse.error(
          Http422,
          "maximumCollateralPerByte must be larger than zero",
          headers = headers,
        )

      let terms = AvailabilityTerms(
        minimumPricePerBytePerSecond: restAv.minimumPricePerBytePerSecond,
        maximumCollateralPerByte: restAv.maximumCollateralPerByte,
        maximumDuration: restAv.maximumDuration,
        availableUntil: restAv.availableUntil,
      )

      if error =? (await marketplace.sales.updateAvailability(terms)).errorOption:
        return RestApiResponse.error(Http500, error.msg, headers = headers)

      return RestApiResponse.response("", Http201, headers = headers)
    except CatchableError as exc:
      trace "Excepting processing request", exc = exc.msg
      return RestApiResponse.error(Http500, headers = headers)

proc initPurchasingApi(node: ArchivistNodeRef, router: var RestRouter) =
  let allowedOrigin = router.allowedOrigin

  router.rawApi(MethodPost, "/api/archivist/v1/storage/request/{cid}") do(
    cid: Cid
  ) -> RestApiResponse:
    var headers = buildCorsHeaders("POST", allowedOrigin)

    ## Create a request for storage
    ##
    ## cid              - the cid of a previously uploaded dataset
    ## duration         - the duration of the request in seconds
    ## proofProbability - how often storage proofs are required
    ## pricePerBytePerSecond - the amount of tokens paid per byte per second to hosts the client is willing to pay
    ## expiry           - specifies threshold in seconds from now when the request expires if the Request does not find requested amount of nodes to host the data
    ## nodes            - number of nodes the content should be stored on
    ## tolerance        - allowed number of nodes that can be lost before content is lost
    ## colateralPerByte - requested collateral per byte from hosts when they fill slot
    try:
      without marketplace =? node.marketplace:
        return RestApiResponse.error(
          Http503, "Persistence is not enabled", headers = headers
        )

      without cid =? cid.tryGet.catch, error:
        return RestApiResponse.error(Http400, error.msg, headers = headers)

      let body = await request.getBody()

      without params =? StorageRequestParams.fromJson(body), error:
        return RestApiResponse.error(Http400, error.msg, headers = headers)

      let expiry = params.expiry

      if expiry.u64 == 0 or expiry >= params.duration:
        return RestApiResponse.error(
          Http422,
          "Expiry must be greater than zero and less than the request's duration",
          headers = headers,
        )

      if params.proofProbability <= 0:
        return RestApiResponse.error(
          Http422, "Proof probability must be greater than zero", headers = headers
        )

      if params.collateralPerByte.u256 == 0:
        return RestApiResponse.error(
          Http422, "Collateral per byte must be greater than zero", headers = headers
        )

      if params.pricePerBytePerSecond.u256 == 0:
        return RestApiResponse.error(
          Http422,
          "Price per byte per second must be greater than zero",
          headers = headers,
        )

      let durationLimit = marketplace.purchasing.durationLimit
      if params.duration > durationLimit:
        return RestApiResponse.error(
          Http422,
          "Duration exceeds limit of " & $durationLimit & " seconds",
          headers = headers,
        )

      let nodes = params.nodes |? 3
      let tolerance = params.tolerance |? 1

      if tolerance == 0:
        return RestApiResponse.error(
          Http422, "Tolerance needs to be bigger then zero", headers = headers
        )

      # prevent underflow
      if tolerance > nodes:
        return RestApiResponse.error(
          Http422,
          "Invalid parameters: `tolerance` cannot be greater than `nodes`",
          headers = headers,
        )

      let ecK = nodes - tolerance
      let ecM = tolerance # for readability

      # ensure leopard constrainst of 1 < K ≥ M
      if ecK <= 1 or ecK < ecM:
        return RestApiResponse.error(
          Http422,
          "Invalid parameters: parameters must satify `1 < (nodes - tolerance) ≥ tolerance`",
          headers = headers,
        )

      without purchaseId =?
        await node.requestStorage(
          cid, params.duration, params.proofProbability, nodes, tolerance,
          params.pricePerBytePerSecond, params.collateralPerByte, expiry,
        ), error:
        if error of InsufficientBlocksError:
          return RestApiResponse.error(
            Http422,
            "Dataset too small for erasure parameters, need at least " &
              $(ref InsufficientBlocksError)(error).minSize.int & " bytes",
            headers = headers,
          )

        return RestApiResponse.error(Http500, error.msg, headers = headers)

      return RestApiResponse.response($purchaseId)
    except CatchableError as exc:
      trace "Excepting processing request", exc = exc.msg
      return RestApiResponse.error(Http500, headers = headers)

  router.api(MethodGet, "/api/archivist/v1/storage/purchases/{id}") do(
    id: PurchaseId
  ) -> RestApiResponse:
    var headers = buildCorsHeaders("GET", allowedOrigin)

    try:
      without marketplace =? node.marketplace:
        return RestApiResponse.error(
          Http503, "Persistence is not enabled", headers = headers
        )

      without id =? id.tryGet.catch, error:
        return RestApiResponse.error(Http400, error.msg, headers = headers)

      without purchase =? marketplace.purchasing.getPurchase(id):
        return RestApiResponse.error(Http404, headers = headers)

      let json =
        %RestPurchase(
          state: purchase.state |? "none",
          error: purchase.error .? msg,
          request: purchase.request,
          requestId: purchase.requestId,
        )

      return RestApiResponse.response(
        $json, contentType = "application/json", headers = headers
      )
    except CatchableError as exc:
      trace "Excepting processing request", exc = exc.msg
      return RestApiResponse.error(Http500, headers = headers)

  router.api(MethodGet, "/api/archivist/v1/storage/purchases") do() -> RestApiResponse:
    var headers = buildCorsHeaders("GET", allowedOrigin)

    try:
      without marketplace =? node.marketplace:
        return RestApiResponse.error(
          Http503, "Persistence is not enabled", headers = headers
        )

      let purchaseIds = marketplace.purchasing.getPurchases()
      return RestApiResponse.response(
        $ %purchaseIds, contentType = "application/json", headers = headers
      )
    except CatchableError as exc:
      trace "Excepting processing request", exc = exc.msg
      return RestApiResponse.error(Http500, headers = headers)

proc initNodeApi(node: ArchivistNodeRef, conf: NodeConf, router: var RestRouter) =
  let allowedOrigin = router.allowedOrigin

  ## various node management api's
  ##
  router.api(MethodGet, "/api/archivist/v1/spr") do() -> RestApiResponse:
    ## Returns node SPR in requested format, json or text.
    ##
    var headers = buildCorsHeaders("GET", allowedOrigin)

    try:
      without spr =? node.discovery.dhtRecord:
        return RestApiResponse.response(
          "", status = Http503, contentType = "application/json", headers = headers
        )

      if $preferredContentType().get() == "text/plain":
        return RestApiResponse.response(
          spr.toURI, contentType = "text/plain", headers = headers
        )
      else:
        return RestApiResponse.response(
          $ %*{"spr": spr.toURI}, contentType = "application/json", headers = headers
        )
    except CatchableError as exc:
      trace "Excepting processing request", exc = exc.msg
      return RestApiResponse.error(Http500, headers = headers)

  router.api(MethodGet, "/api/archivist/v1/peerid") do() -> RestApiResponse:
    ## Returns node's peerId in requested format, json or text.
    ##
    var headers = buildCorsHeaders("GET", allowedOrigin)

    try:
      let id = $node.switch.peerInfo.peerId

      if $preferredContentType().get() == "text/plain":
        return
          RestApiResponse.response(id, contentType = "text/plain", headers = headers)
      else:
        return RestApiResponse.response(
          $ %*{"id": id}, contentType = "application/json", headers = headers
        )
    except CatchableError as exc:
      trace "Excepting processing request", exc = exc.msg
      return RestApiResponse.error(Http500, headers = headers)

  router.api(MethodGet, "/api/archivist/v1/connect/{peerId}") do(
    peerId: PeerId, addrs: seq[MultiAddress]
  ) -> RestApiResponse:
    ## Connect to a peer
    ##
    ## If `addrs` param is supplied, it will be used to
    ## dial the peer, otherwise the `peerId` is used
    ## to invoke peer discovery, if it succeeds
    ## the returned addresses will be used to dial
    ##
    ## `addrs` the listening addresses of the peers to dial, eg the one specified with `--listen-addrs`
    ##
    var headers = buildCorsHeaders("GET", allowedOrigin)

    if peerId.isErr:
      return RestApiResponse.error(Http400, $peerId.error(), headers = headers)

    let addresses =
      if addrs.isOk and addrs.get().len > 0:
        addrs.get()
      else:
        without peerRecord =? (await node.findPeer(peerId.get())):
          return
            RestApiResponse.error(Http400, "Unable to find Peer!", headers = headers)
        peerRecord.addresses.mapIt(it.address)
    try:
      await node.connect(peerId.get(), addresses)
      return
        RestApiResponse.response("Successfully connected to peer", headers = headers)
    except DialFailedError:
      return RestApiResponse.error(Http400, "Unable to dial peer", headers = headers)
    except CatchableError:
      return
        RestApiResponse.error(Http500, "Unknown error dialling peer", headers = headers)

proc initDebugApi(node: ArchivistNodeRef, conf: NodeConf, router: var RestRouter) =
  let allowedOrigin = router.allowedOrigin

  router.api(MethodGet, "/api/archivist/v1/debug/info") do() -> RestApiResponse:
    ## Print rudimentary node information
    ##
    var headers = buildCorsHeaders("GET", allowedOrigin)

    try:
      let table = RestRoutingTable.init(node.discovery.protocol.routingTable)

      let json =
        %*{
          "id": $node.switch.peerInfo.peerId,
          "addrs": node.switch.peerInfo.addrs.mapIt($it),
          "repo": $conf.dataDir,
          "spr":
            if node.discovery.dhtRecord.isSome:
              node.discovery.dhtRecord.get.toURI
            else:
              "",
          "announceAddresses": node.discovery.announceAddrs,
          "ethAddress": node.ethAddress,
          "table": table,
          "archivist": {
            "version": $nodeVersion,
            "revision": $nodeRevision,
            "contracts": $contractsRevision,
          },
        }

      # return pretty json for human readability
      return RestApiResponse.response(
        json.pretty(), contentType = "application/json", headers = headers
      )
    except CatchableError as exc:
      trace "Excepting processing request", exc = exc.msg
      return RestApiResponse.error(Http500, headers = headers)

  router.api(MethodPost, "/api/archivist/v1/debug/chronicles/loglevel") do(
    level: Option[string]
  ) -> RestApiResponse:
    ## Set log level at run time
    ##
    ## e.g. `chronicles/loglevel?level=DEBUG`
    ##
    ## `level` - chronicles log level
    ##
    var headers = buildCorsHeaders("POST", allowedOrigin)

    try:
      without res =? level and level =? res:
        return RestApiResponse.error(Http400, "Missing log level", headers = headers)

      try:
        {.gcsafe.}:
          updateLogLevel(level)
      except CatchableError as exc:
        return RestApiResponse.error(Http500, exc.msg, headers = headers)

      return RestApiResponse.response("")
    except CatchableError as exc:
      trace "Excepting processing request", exc = exc.msg
      return RestApiResponse.error(Http500, headers = headers)

  when defined(archivist_system_testing_options):
    router.api(MethodGet, "/api/archivist/v1/debug/peer/{peerId}") do(
      peerId: PeerId
    ) -> RestApiResponse:
      var headers = buildCorsHeaders("GET", allowedOrigin)

      try:
        trace "debug/peer start"
        without peerRecord =? (await node.findPeer(peerId.get())):
          trace "debug/peer peer not found!"
          return
            RestApiResponse.error(Http400, "Unable to find Peer!", headers = headers)

        let json = %RestPeerRecord.init(peerRecord)
        trace "debug/peer returning peer record"
        return RestApiResponse.response($json, headers = headers)
      except CatchableError as exc:
        trace "Excepting processing request", exc = exc.msg
        return RestApiResponse.error(Http500, headers = headers)

    router.api(MethodPost, "/api/archivist/v1/debug/testing/option/{key}/{value}") do(
      key: string, value: string
    ) -> RestApiResponse:
      var headers = buildCorsHeaders("GET", allowedOrigin)
      try:
        let
          keyStr = key.get()
          valueInt = parseInt(value.get())

        if keyStr == "simulate_proof_failures":
          node.marketplace.get().sales.simulateProofFailures(valueInt)
        elif keyStr == "dht_send_fail_probability":
          node.discovery.protocol.transport.sendFailProb = valueInt
        else:
          raise newException(Defect, "Unknown system testing option key: " & keyStr)

        trace "set system testing option", key = keyStr, value = valueInt
        return RestApiResponse.response(Http200, headers = headers)
      except CatchableError as exc:
        # This call is used for system level testing. Should anything here fail,
        # the results of tests that rely on this functionality can't be trusted.
        # So we need to know about this error immediately.
        # Therefore we crash the node.
        let msg =
          "Failed to set system testing option. key: " & $key & " value: " & $value
        error "Failure in system testing options", err = msg
        raiseAssert(msg)

proc initRestApi*(
    node: ArchivistNodeRef,
    conf: NodeConf,
    repoStore: RepoStore,
    corsAllowedOrigin: ?string,
): RestRouter =
  var router = RestRouter.init(validate, corsAllowedOrigin)

  initDataApi(node, repoStore, router)
  initSalesApi(node, router)
  initPurchasingApi(node, router)
  initNodeApi(node, conf, router)
  initDebugApi(node, conf, router)

  return router
