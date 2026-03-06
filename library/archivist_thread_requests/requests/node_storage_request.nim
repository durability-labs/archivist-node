## This file contains the node storage request.
## Operations available:
## - LIST: list all manifests stored in the node.
## - DELETE: Deletes either a single block or an entire dataset from the local node.
## - FETCH: download a file from the network to the local node.
## - SPACE: get the amount of space used by the local node.
## - EXISTS: check the existence of a cid in a node (local store).

{.push raises: [].}

import std/[options, tables]
import chronos
import chronicles
import libp2p/stream/[lpstream]
import serde/json as serde
import ../../alloc
import ../../../archivist/units
import ../../../archivist/archivisttypes
import ../../../archivist/manifest/manifest

from "../../../archivist/archivist" import NodeServer
from ../../../archivist/node import
  ArchivistNodeRef, iterateManifests, fetchManifest, fetchDatasetAsyncTask, delete
from libp2p import Cid, init, `$`

logScope:
  topics = "libarchivist libarchiviststorage"

type NodeStorageMsgType* = enum
  LIST
  DELETE
  FETCH
  SPACE
  EXISTS

type NodeStorageRequest* = object
  operation: NodeStorageMsgType
  cid: cstring

type StorageSpace = object
  totalBlocks* {.serialize.}: Natural
  quotaMaxBytes* {.serialize.}: NBytes
  quotaUsedBytes* {.serialize.}: NBytes
  quotaReservedBytes* {.serialize.}: NBytes

proc createShared*(
    T: type NodeStorageRequest, op: NodeStorageMsgType, cid: cstring = ""
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].cid = cid.alloc()

  return ret

proc destroyShared(self: ptr NodeStorageRequest) =
  if not self.isNil:
    deallocShared(self[].cid)
    deallocShared(self)

proc cleanupRequest(self: ptr NodeStorageRequest) =
  if not self.isNil:
    deallocShared(self[].cid)

type ManifestWithCid = object
  cid {.serialize.}: string
  manifest {.serialize.}: Manifest

proc list(
    archivist: ptr NodeServer
): Future[Result[string, string]] {.async: (raises: []).} =
  var manifests = newSeq[ManifestWithCid]()
  proc onManifest(cid: Cid, manifest: Manifest) {.raises: [], gcsafe.} =
    manifests.add(ManifestWithCid(cid: $cid, manifest: manifest))

  try:
    await archivist[].archivistNode.iterateManifests(onManifest)
  except CancelledError:
    return err("Failed to list manifests: cancelled operation.")
  except CatchableError as err:
    return err("Failed to list manifest: : " & err.msg)

  return ok(serde.toJson(manifests))

proc delete(
    archivist: ptr NodeServer, cCid: cstring
): Future[Result[string, string]] {.async: (raises: []).} =
  let cid = Cid.init($cCid)
  if cid.isErr:
    return err("Failed to delete the data: cannot parse cid: " & $cCid)

  try:
    let res = await archivist[].archivistNode.delete(cid.get())
    if res.isErr:
      return err("Failed to delete the data: " & res.error.msg)
  except CancelledError:
    return err("Failed to delete the data: cancelled operation.")
  except CatchableError as err:
    return err("Failed to delete the data: " & err.msg)

  return ok("")

proc fetch(
    archivist: ptr NodeServer, cCid: cstring
): Future[Result[string, string]] {.async: (raises: []).} =
  let cid = Cid.init($cCid)
  if cid.isErr:
    return err("Failed to fetch the data: cannot parse cid: " & $cCid)

  try:
    let manifest = await archivist[].archivistNode.fetchManifest(cid.get())
    if manifest.isErr:
      return err("Failed to fetch the data: " & manifest.error.msg)

    archivist[].archivistNode.fetchDatasetAsyncTask(manifest.get())

    return ok(serde.toJson(manifest.get()))
  except CancelledError:
    return err("Failed to fetch the data: download cancelled.")

proc space(
    archivist: ptr NodeServer
): Future[Result[string, string]] {.async: (raises: []).} =
  try:
    # TODO: Implementation missing, need to query repo store
    let space = StorageSpace(
      totalBlocks: 0,
      quotaMaxBytes: 0.NBytes,
      quotaUsedBytes: 0.NBytes,
      quotaReservedBytes: 0.NBytes,
    )
    return ok(serde.toJson(space))
  except CatchableError as err:
    return err("Failed to get space: " & err.msg)

proc hasLocalBlock(
    archivist: ptr NodeServer, cid: Cid
): Future[bool] {.async: (raises: []).} =
  # TODO: Implement proper block existence check
  return false

proc exists(
    archivist: ptr NodeServer, cCid: cstring
): Future[Result[string, string]] {.async: (raises: []).} =
  let cid = Cid.init($cCid)
  if cid.isErr:
    return err("Failed to check the data existence: cannot parse cid: " & $cCid)

  try:
    let exists = await hasLocalBlock(archivist, cid.get())
    return ok($exists)
  except CancelledError:
    return err("Failed to check the data existence: operation cancelled.")

proc process*(
    self: ptr NodeStorageRequest, archivist: ptr NodeServer
): Future[Result[string, string]] {.async: (raises: []).} =
  defer:
    destroyShared(self)

  case self.operation
  of NodeStorageMsgType.LIST:
    let res = (await list(archivist))
    if res.isErr:
      error "Failed to LIST.", error = res.error
      return err($res.error)
    return res
  of NodeStorageMsgType.DELETE:
    let res = (await delete(archivist, self.cid))
    if res.isErr:
      error "Failed to DELETE.", error = res.error
      return err($res.error)
    return res
  of NodeStorageMsgType.FETCH:
    let res = (await fetch(archivist, self.cid))
    if res.isErr:
      error "Failed to FETCH.", error = res.error
      return err($res.error)
    return res
  of NodeStorageMsgType.SPACE:
    let res = (await space(archivist))
    if res.isErr:
      error "Failed to SPACE.", error = res.error
      return err($res.error)
    return res
  of NodeStorageMsgType.EXISTS:
    let res = (await exists(archivist, self.cid))
    if res.isErr:
      error "Failed to EXISTS.", error = res.error
      return err($res.error)
    return res
