## Copyright (c) 2025 Archivist Authors
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## DatasetStore - Persistent storage for overlay metadata
##
## Provides CRUD for OverlayMetadata using KVStore with CAS semantics.
## Keys use treeCid as the canonical dataset identifier.

{.push raises: [].}

import std/tables

import pkg/chronos
import pkg/kvstore/kvstore
import pkg/kvstore/query
import pkg/libp2p/cid
import pkg/questionable
import pkg/questionable/results

import ./coders
import ./types
import ../errors
import ../keys
import ../logutils

export types

logScope:
  topics = "archivist datasetstore"

type DatasetStore* = ref object ## Persistent storage for dataset overlay metadata
  metaStore*: KVStore
  overlays*: Table[Cid, OverlayState] ## In-memory cache

func new*(T: type DatasetStore, metaStore: KVStore): DatasetStore =
  DatasetStore(metaStore: metaStore, overlays: initTable[Cid, OverlayState]())

proc getOverlayMetadata*(
    self: DatasetStore, treeCid: Cid
): Future[?!OverlayMetadata] {.async: (raises: [CancelledError]).} =
  logScope:
    treeCid = treeCid

  if self.overlays.hasKey(treeCid):
    trace "Overlay metadata found in cache"
    return success(self.overlays.getOrDefault(treeCid).metadata)

  without key =? datasetOverlayKey(treeCid), err:
    return failure(err)

  without record =? await self.metaStore.get(key), err:
    trace "Overlay metadata not found", err = err.msg
    return failure(err)

  without meta =? OverlayMetadata.decode(record.val), err:
    return failure(err)

  trace "Overlay metadata loaded from store"
  success(meta)

proc setOverlayMetadata*(
    self: DatasetStore, treeCid: Cid, meta: OverlayMetadata
): Future[?!void] {.async: (raises: [CancelledError]).} =
  logScope:
    treeCid = treeCid
    status = meta.status

  without key =? datasetOverlayKey(treeCid), err:
    return failure(err)

  var token: uint64 = 0
  if existingRecord =? await self.metaStore.get(key):
    token = existingRecord.token

  let record = RawRecord.init(key, meta.encode(), token)
  ?await self.metaStore.put(record)

  self.overlays[treeCid] = OverlayState(metadata: meta, presentBlocks: 0)

  trace "Overlay metadata stored"
  success()

proc deleteOverlayMetadata*(
    self: DatasetStore, treeCid: Cid
): Future[?!void] {.async: (raises: [CancelledError]).} =
  logScope:
    treeCid = treeCid

  without key =? datasetOverlayKey(treeCid), err:
    return failure(err)

  without existingRecord =? await self.metaStore.get(key), err:
    trace "Overlay metadata not found for deletion"
    return success()

  ?await self.metaStore.delete(KeyRecord.init(key, existingRecord.token))

  self.overlays.del(treeCid)

  trace "Overlay metadata deleted"
  success()

proc listDatasets*(
    self: DatasetStore
): Future[?!seq[Cid]] {.async: (raises: [CancelledError]).} =
  without queryKey =? datasetsQueryKey(), err:
    return failure(err)

  without iter =? await self.metaStore.query(Query.init(queryKey)), err:
    return failure(err)

  var datasets = newSeq[Cid]()
  while not iter.finished:
    without recordOpt =? await iter.next(), err:
      warn "Error iterating datasets", err = err.msg
      continue
    without record =? recordOpt:
      continue # End of iteration
    without cid =? Cid.init(record.key.value).mapFailure, err:
      warn "Failed to parse CID from key", key = record.key, err = err.msg
      continue
    datasets.add(cid)

  iter.dispose()
  success(datasets)

proc listDatasetsInState*(
    self: DatasetStore, status: DatasetStatus
): Future[?!seq[Cid]] {.async: (raises: [CancelledError]).} =
  without queryKey =? datasetsQueryKey(), err:
    return failure(err)

  without iter =? await self.metaStore.query(Query.init(queryKey)), err:
    return failure(err)

  var datasets = newSeq[Cid]()
  while not iter.finished:
    without recordOpt =? await iter.next(), err:
      warn "Error iterating datasets", err = err.msg
      continue
    without record =? recordOpt:
      continue # End of iteration
    without meta =? OverlayMetadata.decode(record.val), err:
      warn "Failed to decode metadata", err = err.msg
      continue
    if meta.status != status:
      continue
    without cid =? Cid.init(record.key.value).mapFailure, err:
      warn "Failed to parse CID from key", key = record.key, err = err.msg
      continue
    datasets.add(cid)

  iter.dispose()
  success(datasets)

proc close*(self: DatasetStore): Future[?!void] {.async: (raises: [CancelledError]).} =
  trace "Closing DatasetStore"
  self.overlays.clear()
  await self.metaStore.close()
