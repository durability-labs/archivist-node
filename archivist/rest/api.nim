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
import std/tables
import std/strutils
import std/algorithm
from std/json import parseJson, JsonParsingError

import pkg/questionable
import pkg/questionable/results
import pkg/chronos
import pkg/presto except toJson
import pkg/metrics except toJson
import pkg/stew/base10
import pkg/stew/byteutils
import pkg/confutils

import pkg/libp2p
import pkg/libp2p/routing_record
import pkg/archivistdht/discv5/spr as spr

import ../logutils
import ../node
import ../directorynode
import ../blocktype
import ../conf
import ../erasure/erasure
import ../manifest
import ../manifest/directory
import ../streams/asyncstreamwrapper
import ../stores
import ../marketplace
import ../marketplace/abstractmarketplace
import ../purchasing
import ../sales/reservations

import ./coders
import ./json
import ./directoryhtml

logScope:
  topics = "archivist restapi"

declareCounter(archivist_api_uploads, "archivist API uploads")
declareCounter(archivist_api_downloads, "archivist API downloads")

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
        buff = newSeqUninitialized[byte](DefaultBlockSize.int)
        len = await stream.readOnce(addr buff[0], buff.len)

      buff.setLen(len)
      if buff.len <= 0:
        break

      bytes += buff.len

      await resp.send(addr buff[0], buff.len)
    await resp.finish()
    archivist_api_downloads.inc()
  except CancelledError as exc:
    raise exc
  except LPStreamError as exc:
    warn "Error streaming blocks", exc = exc.msg
    resp.status = Http500
    if resp.isPending():
      await resp.sendBody(exc.msg)
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
      # Add formats missing from std/mimetypes
      m.register("xml", "application/xml")
      m.register("xml", "text/xml")
      m.register("flac", "audio/flac")
      m.register("mp3", "audio/mpeg")
      m.register("opus", "audio/opus")
      m.register("m4a", "audio/mp4")
      m.register("m4a", "audio/x-m4a")
      m.register("aac", "audio/aac")
      m.register("wma", "audio/x-ms-wma")
      m.register("mkv", "video/x-matroska")
      m.register("webm", "video/webm")
      m.register("ts", "video/mp2t")
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

    # Validate filename - only block null bytes and literal "." or ".."
    # Forward slashes are allowed (relative paths for directory uploads like "Album/track.mp3")
    # Backslashes are normalized to forward slashes
    if filename.isSome:
      let fname = filename.get().replace('\\', '/')
      if fname.len == 0 or fname == "." or fname == ".." or '\0' in fname:
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

  router.api(MethodOptions, "/api/archivist/v1/directory") do(
    resp: HttpResponseRef
  ) -> RestApiResponse:
    if corsOrigin =? allowedOrigin:
      resp.setCorsHeaders("POST", corsOrigin)
      resp.setHeader(
        "Access-Control-Allow-Headers", "content-type, x-pubkey"
      )

    resp.status = Http204
    await resp.sendBody("")

  router.rawApi(MethodPost, "/api/archivist/v1/directory") do() -> RestApiResponse:
    ## Finalize a directory from pre-uploaded files
    ##
    ## Accepts JSON with array of entries, each containing:
    ##   - path: string (e.g., "folder/file.mp3")
    ##   - cid: string (CID of already-uploaded file)
    ##   - size: int (file size in bytes)
    ##   - mimetype: string (optional)
    ##
    ## Returns JSON with root directory CID
    ##
    trace "Handling directory finalize"

    var headers = buildCorsHeaders("POST", allowedOrigin)

    # Parse JSON body
    let body = await request.getBody()
    var jsonBody: JsonNode
    try:
      jsonBody = parseJson(cast[string](body))
    except JsonParsingError:
      return RestApiResponse.error(
        Http400, "Invalid JSON body", headers = headers
      )

    # Validate structure
    if not jsonBody.hasKey("entries"):
      return RestApiResponse.error(
        Http400, "Missing 'entries' array in request body", headers = headers
      )

    let entriesJson = jsonBody["entries"]
    if entriesJson.kind != JArray:
      return RestApiResponse.error(
        Http400, "'entries' must be an array", headers = headers
      )

    if entriesJson.len == 0:
      return RestApiResponse.error(
        Http400, "No entries provided", headers = headers
      )

    # Parse entries
    type InputEntry = object
      path: string
      cid: Cid
      size: NBytes
      mimetype: ?string

    var inputEntries: seq[InputEntry]

    for i, entry in entriesJson.elems:
      if entry.kind != JObject:
        return RestApiResponse.error(
          Http400, "Entry " & $i & " must be an object", headers = headers
        )

      if not entry.hasKey("path") or not entry.hasKey("cid"):
        return RestApiResponse.error(
          Http400, "Entry " & $i & " missing required 'path' or 'cid'", headers = headers
        )

      let pathStr = entry["path"].getStr()
      let cidStr = entry["cid"].getStr()

      # Validate and normalize path
      var normalPath = pathStr.replace("\\", "/")
      while normalPath.len > 0 and normalPath[0] == '/':
        normalPath = normalPath[1..^1]

      # Check for directory traversal - ".." must be a path segment, not part of filename
      # Valid: "F.R.E.S.H..mp3" (double dot in filename)
      # Invalid: "../etc/passwd" or "foo/../bar"
      let pathParts = normalPath.split('/')
      for part in pathParts:
        if part == "..":
          return RestApiResponse.error(
            Http400, "Invalid path (directory traversal not allowed): " & pathStr,
            headers = headers,
          )

      if normalPath.len == 0:
        continue

      # Parse CID
      without cidVal =? Cid.init(cidStr).mapFailure, err:
        return RestApiResponse.error(
          Http400, "Entry " & $i & " has invalid CID: " & cidStr, headers = headers
        )

      let size = NBytes(entry.getOrDefault("size").getInt(0))
      let mimetypeOpt =
        if entry.hasKey("mimetype") and entry["mimetype"].getStr().len > 0:
          entry["mimetype"].getStr().some
        else:
          string.none

      inputEntries.add(InputEntry(
        path: normalPath,
        cid: cidVal,
        size: size,
        mimetype: mimetypeOpt,
      ))

    trace "Parsed directory finalize request", entries = inputEntries.len

    # Build directory tree from bottom up
    # Group files by their parent directory
    type DirNode = ref object
      name: string
      files: seq[tuple[name: string, cid: Cid, size: NBytes, mimetype: ?string]]
      subdirs: Table[string, DirNode]

    var root = DirNode(name: "", subdirs: initTable[string, DirNode]())

    for entry in inputEntries:
      let pathParts = entry.path.split('/')
      var current = root

      # Navigate/create directory structure
      for i in 0 ..< pathParts.len - 1:
        let part = pathParts[i]
        if part notin current.subdirs:
          current.subdirs[part] = DirNode(
            name: part,
            subdirs: initTable[string, DirNode](),
          )
        current = current.subdirs[part]

      # Add file to current directory
      current.files.add((
        name: pathParts[^1],
        cid: entry.cid,
        size: entry.size,
        mimetype: entry.mimetype,
      ))

    # If root has exactly one subdir and no files, promote that subdir to root
    # This makes "MyAlbum/track1.mp3" become a directory named "MyAlbum" at root
    # instead of having an anonymous root containing "MyAlbum"
    while root.subdirs.len == 1 and root.files.len == 0:
      for name, subdir in root.subdirs.pairs:
        root = subdir
        break

    # Recursively create directory manifests from leaves to root
    proc buildDirManifest(dirNode: DirNode): Future[?!Cid] {.async.} =
      var entries: seq[DirectoryEntry]

      # First, process subdirectories (they need their CIDs computed first)
      for name, subdir in dirNode.subdirs.pairs:
        without subdirCid =? (await buildDirManifest(subdir)), err:
          return failure(err)

        # We need the total size of the subdirectory
        without subdirManifest =? (
          await fetchDirectoryManifest(node.networkStore, subdirCid)
        ), err:
          return failure(err)

        entries.add(DirectoryEntry.new(
          name = name,
          cid = subdirCid,
          size = subdirManifest.totalSize,
          isDirectory = true,
        ))

      # Add files
      for f in dirNode.files:
        entries.add(DirectoryEntry.new(
          name = f.name,
          cid = f.cid,
          size = f.size,
          isDirectory = false,
          mimetype = if f.mimetype.isSome: f.mimetype.unsafeGet() else: "",
        ))

      # Sort entries: directories first, then files, alphabetically
      entries.sort(proc(a, b: DirectoryEntry): int =
        if a.isDirectory and not b.isDirectory:
          return -1
        elif not a.isDirectory and b.isDirectory:
          return 1
        else:
          return cmp(a.name, b.name)
      )

      let dirManifest = DirectoryManifest.new(
        entries = entries,
        name = dirNode.name,
      )

      without blk =? (await storeDirectoryManifest(node.networkStore, dirManifest)), err:
        return failure(err)

      return blk.cid.success

    without rootCid =? (await buildDirManifest(root)), err:
      error "Error building directory manifest", exc = err.msg
      return RestApiResponse.error(Http500, err.msg, headers = headers)

    without rootDir =? (await fetchDirectoryManifest(node.networkStore, rootCid)), err:
      return RestApiResponse.error(Http500, err.msg, headers = headers)

    archivist_api_uploads.inc()

    # Build JSON response directly (RestDirectoryUploadResponse causes serialization issues)
    var responseJson = newJObject()
    responseJson["cid"] = %rootCid
    responseJson["totalSize"] = %(rootDir.totalSize.int)
    responseJson["filesCount"] = %rootDir.filesCount
    return RestApiResponse.response(
      $responseJson, contentType = "application/json", headers = headers
    )

  router.api(MethodOptions, "/api/archivist/v1/data/{cid}") do(
    cid: Cid, resp: HttpResponseRef
  ) -> RestApiResponse:
    if corsOrigin =? allowedOrigin:
      resp.setCorsHeaders("GET,HEAD,DELETE", corsOrigin)

    resp.status = Http204
    await resp.sendBody("")

  router.api(MethodHead, "/api/archivist/v1/data/{cid}") do(
    cid: Cid, resp: HttpResponseRef
  ) -> RestApiResponse:
    ## HEAD request - returns headers without body
    ## Used to check content type and size before fetching
    var headers = buildCorsHeaders("HEAD", allowedOrigin)

    if cid.isErr:
      return RestApiResponse.error(Http400, $cid.error(), headers = headers)

    let cidVal = cid.get()

    if corsOrigin =? allowedOrigin:
      resp.setCorsHeaders("HEAD", corsOrigin)

    # Check if this is a directory manifest
    without isDir =? cidVal.isDirectory, err:
      return RestApiResponse.error(Http400, err.msg, headers = headers)

    if isDir:
      # Directory - check if it exists
      without directory =? (await fetchDirectoryManifest(node.networkStore, cidVal)), err:
        return RestApiResponse.error(Http404, err.msg, headers = headers)

      # Check Accept header to determine response format
      let acceptHeader = request.headers.getString("Accept")
      if "application/json" in acceptHeader:
        resp.setHeader("Content-Type", "application/json")
      else:
        resp.setHeader("Content-Type", "text/html; charset=utf-8")
      resp.setHeader("Content-Length", $(directory.totalSize.int))
      resp.status = Http200
      await resp.sendBody("")

    else:
      # Regular file - get manifest for headers
      without manifest =? (await node.fetchManifest(cidVal)), err:
        return RestApiResponse.error(Http404, err.msg, headers = headers)

      if manifest.mimetype.isSome:
        resp.setHeader("Content-Type", manifest.mimetype.get())
      else:
        resp.setHeader("Content-Type", "application/octet-stream")

      let contentLength =
        if manifest.protected: manifest.originalDatasetSize else: manifest.datasetSize
      resp.setHeader("Content-Length", $(contentLength.int))

      if manifest.filename.isSome:
        resp.setHeader("Content-Disposition",
          "attachment; filename=\"" & manifest.filename.get() & "\"")

      resp.status = Http200
      await resp.sendBody("")

  router.api(MethodGet, "/api/archivist/v1/data/{cid}") do(
    cid: Cid, resp: HttpResponseRef
  ) -> RestApiResponse:
    var headers = buildCorsHeaders("GET", allowedOrigin)

    ## Download a file from the local node in a streaming manner,
    ## or browse a directory manifest (returning HTML or JSON)
    if cid.isErr:
      return RestApiResponse.error(Http400, $cid.error(), headers = headers)

    let cidVal = cid.get()

    if corsOrigin =? allowedOrigin:
      resp.setCorsHeaders("GET", corsOrigin)
      resp.setHeader("Access-Control-Headers", "X-Requested-With")

    # Check if this is a directory manifest
    without isDir =? cidVal.isDirectory, err:
      return RestApiResponse.error(Http400, err.msg, headers = headers)

    if isDir:
      # This is a directory - return HTML or JSON listing
      without directory =? (await fetchDirectoryManifest(node.networkStore, cidVal)), err:
        return RestApiResponse.error(Http404, err.msg, headers = headers)

      # Check Accept header to determine response format
      let acceptHeader = request.headers.getString("Accept")

      if "text/html" in acceptHeader or "text/*" in acceptHeader or "*/*" in acceptHeader:
        # Return HTML directory listing
        let html = generateDirectoryHtml(directory, cidVal)
        return RestApiResponse.response(html, contentType = "text/html; charset=utf-8")
      else:
        # Return JSON (build directly to avoid serialization issues with RestDirectory)
        var entriesJson = newJArray()
        for entry in directory.entries:
          var entryJson = newJObject()
          entryJson["name"] = %entry.name
          entryJson["cid"] = %($entry.cid)
          entryJson["size"] = %(entry.size.int)
          entryJson["isDirectory"] = %entry.isDirectory
          if entry.mimetype.len > 0:
            entryJson["mimetype"] = %entry.mimetype
          entriesJson.add(entryJson)

        var json = newJObject()
        json["cid"] = %($cidVal)
        if directory.name.len > 0:
          json["name"] = %directory.name
        json["totalSize"] = %(directory.totalSize.int)
        json["entries"] = entriesJson
        return RestApiResponse.response($json, contentType = "application/json", headers = headers)

    # Regular file - stream it
    await node.retrieveCid(cidVal, local = true, resp = resp)

  router.api(MethodDelete, "/api/archivist/v1/data/{cid}") do(
    cid: Cid, resp: HttpResponseRef
  ) -> RestApiResponse:
    ## Deletes either a single block or an entire dataset
    ## from the local node. Does nothing and returns 204
    ## if the dataset is not locally available.
    ##
    var headers = buildCorsHeaders("DELETE", allowedOrigin)

    if cid.isErr:
      return RestApiResponse.error(Http400, $cid.error(), headers = headers)

    if err =? (await node.delete(cid.get())).errorOption:
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

  router.api(MethodHead, "/api/archivist/v1/data/{cid}/network/stream") do(
    cid: Cid, resp: HttpResponseRef
  ) -> RestApiResponse:
    ## HEAD request for network stream - returns headers without body
    ##
    var headers = buildCorsHeaders("HEAD", allowedOrigin)

    if cid.isErr:
      return RestApiResponse.error(Http400, $cid.error(), headers = headers)

    if corsOrigin =? allowedOrigin:
      resp.setCorsHeaders("HEAD", corsOrigin)

    # For streaming endpoint, just return 200 with audio content type
    # The actual content-length isn't known without fetching
    resp.setHeader("Content-Type", "application/octet-stream")
    resp.setHeader("Accept-Ranges", "bytes")
    resp.status = Http200
    await resp.sendBody("")

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

  # Path resolution within directories
  router.api(MethodGet, "/api/archivist/v1/data/{cid}/path") do(
    cid: Cid, p: Option[string], resp: HttpResponseRef
  ) -> RestApiResponse:
    ## Access a file or subdirectory within a directory by path
    ## Use query parameter ?p=images/logo.png
    ##
    var headers = buildCorsHeaders("GET", allowedOrigin)

    if cid.isErr:
      return RestApiResponse.error(Http400, $cid.error(), headers = headers)

    let cidVal = cid.get()

    # Get path from query parameter (Option[Result[string, cstring]])
    var pathStr = ""
    if pOpt =? p:
      if pRes =? pOpt:
        pathStr = pRes
    let pathParts = if pathStr.len > 0: pathStr.split('/') else: @[]

    if pathParts.len == 0:
      # Redirect to directory listing
      return RestApiResponse.redirect(
        Http307, "/api/archivist/v1/data/" & $cidVal
      )

    # Check if this is a directory manifest
    without isDir =? cidVal.isDirectory, err:
      return RestApiResponse.error(Http400, err.msg, headers = headers)

    if not isDir:
      return RestApiResponse.error(
        Http400, "CID is not a directory manifest", headers = headers
      )

    without directory =? (await fetchDirectoryManifest(node.networkStore, cidVal)), err:
      return RestApiResponse.error(Http404, err.msg, headers = headers)

    # Resolve the path
    var currentDir = directory
    var currentCid = cidVal

    for i, part in pathParts:
      if part == "":
        continue

      var foundEntry: DirectoryEntry
      if not currentDir.findEntry(part, foundEntry):
        return RestApiResponse.error(
          Http404, "Path not found: " & part, headers = headers
        )

      if i == pathParts.high:
        # This is the last path component
        if foundEntry.isDirectory:
          # Redirect to directory listing
          return RestApiResponse.redirect(
            Http307, "/api/archivist/v1/data/" & $foundEntry.cid
          )
        else:
          # Serve the file
          if corsOrigin =? allowedOrigin:
            resp.setCorsHeaders("GET", corsOrigin)
            resp.setHeader("Access-Control-Headers", "X-Requested-With")

          resp.setHeader("Access-Control-Expose-Headers", "Content-Disposition")
          await node.retrieveCid(foundEntry.cid, local = true, resp = resp)
          return RestApiResponse.response("")
      else:
        # Navigate into subdirectory
        if not foundEntry.isDirectory:
          return RestApiResponse.error(
            Http400, "Path component is not a directory: " & part, headers = headers
          )

        without subDir =? (await fetchDirectoryManifest(node.networkStore, foundEntry.cid)), err:
          return RestApiResponse.error(Http404, err.msg, headers = headers)

        currentDir = subDir
        currentCid = foundEntry.cid

    # Should not reach here
    return RestApiResponse.error(Http500, "Unexpected error", headers = headers)

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

      if restAv.maximumDuration == 0:
        return RestApiResponse.error(
          Http422, "maximumDuration must be larger than zero", headers = headers
        )

      if restAv.minimumPricePerBytePerSecond == 0:
        return RestApiResponse.error(
          Http422,
          "minimumPricePerBytePerSecond must be larger than zero",
          headers = headers,
        )

      if restAv.maximumCollateralPerByte == 0:
        return RestApiResponse.error(
          Http422,
          "maximumCollateralPerByte must be larger than zero",
          headers = headers,
        )

      if availableUntil =? restAv.availableUntil and availableUntil < 0:
        return RestApiResponse.error(
          Http422, "availableUntil must not be negative", headers = headers
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

  router.api(MethodOptions, "/api/archivist/v1/sales/availability/{id}") do(
    id: AvailabilityId, resp: HttpResponseRef
  ) -> RestApiResponse:
    if corsOrigin =? allowedOrigin:
      resp.setCorsHeaders("PATCH", corsOrigin)

    resp.status = Http204
    await resp.sendBody("")

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

      if expiry <= 0 or expiry >= params.duration:
        return RestApiResponse.error(
          Http422,
          "Expiry must be greater than zero and less than the request's duration",
          headers = headers,
        )

      if params.proofProbability <= 0:
        return RestApiResponse.error(
          Http422, "Proof probability must be greater than zero", headers = headers
        )

      if params.collateralPerByte <= 0:
        return RestApiResponse.error(
          Http422, "Collateral per byte must be greater than zero", headers = headers
        )

      if params.pricePerBytePerSecond <= 0:
        return RestApiResponse.error(
          Http422,
          "Price per byte per second must be greater than zero",
          headers = headers,
        )

      let requestDurationLimit =
        await marketplace.purchasing.marketplace.requestDurationLimit
      if params.duration > requestDurationLimit:
        return RestApiResponse.error(
          Http422,
          "Duration exceeds limit of " & $requestDurationLimit & " seconds",
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

      return RestApiResponse.response(purchaseId.toHex)
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
          node.marketplace.get().sales.context.simulateProofFailures = valueInt
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
