## Copyright (c) 2025 Archivist Authors
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## DatasetStore - Persistent storage for dataset overlay metadata
##
## Provides CRUD operations for OverlayMetadata using KVStore with
## CAS (Compare-And-Swap) semantics for optimistic concurrency control.

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
    self: DatasetStore, manifestCid: Cid
): Future[?!OverlayMetadata] {.async: (raises: [CancelledError]).} =
  logScope:
    manifestCid = manifestCid

  # Check in-memory cache first
  if self.overlays.hasKey(manifestCid):
    trace "Overlay metadata found in cache"
    return success(self.overlays.getOrDefault(manifestCid).metadata)

  # Load from kvstore
  without key =? datasetOverlayKey(manifestCid), err:
    return failure(err)

  without record =? await self.metaStore.get(key), err:
    trace "Overlay metadata not found", err = err.msg
    return failure(err)

  without meta =? OverlayMetadata.decode(record.val), err:
    return failure(err)

  trace "Overlay metadata loaded from store"
  success(meta)

proc setOverlayMetadata*(
    self: DatasetStore, manifestCid: Cid, meta: OverlayMetadata
): Future[?!void] {.async: (raises: [CancelledError]).} =
  logScope:
    manifestCid = manifestCid
    status = meta.status

  without key =? datasetOverlayKey(manifestCid), err:
    return failure(err)

  # Get existing record to obtain its token (for CAS), or use 0 for new record
  var token: uint64 = 0
  if existingRecord =? await self.metaStore.get(key):
    token = existingRecord.token

  let record = RawRecord.init(key, meta.encode(), token)
  ?await self.metaStore.put(record)

  # Update in-memory cache - always overwrite with new state
  self.overlays[manifestCid] = OverlayState(metadata: meta, presentBlocks: 0)

  trace "Overlay metadata stored"
  success()

proc deleteOverlayMetadata*(
    self: DatasetStore, manifestCid: Cid
): Future[?!void] {.async: (raises: [CancelledError]).} =
  logScope:
    manifestCid = manifestCid

  without key =? datasetOverlayKey(manifestCid), err:
    return failure(err)

  # Get existing record to obtain its token (for CAS)
  without existingRecord =? await self.metaStore.get(key), err:
    # If not found, that's fine - nothing to delete
    trace "Overlay metadata not found for deletion"
    return success()

  ?await self.metaStore.delete(KeyRecord.init(key, existingRecord.token))

  # Remove from cache
  self.overlays.del(manifestCid)

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
