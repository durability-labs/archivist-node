## Copyright (c) 2025 Archivist Authors
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## Overlay metadata operations - storing, retrieving, and listing dataset overlays

{.push raises: [].}

import std/algorithm

import pkg/chronos
import pkg/kvstore
import pkg/libp2p/cid
import pkg/results
import pkg/questionable
import pkg/questionable/results

import ./coders
import ../types
import ../../keyutils

import ../../queryiterhelper

import ../../../utils
import ../../../errors
import ../../../logutils

export coders

logScope:
  topics = "archivist repostore overlays"

proc putOverlayMetadata*(
    self: RepoStore, treeCid: Cid, meta: OverlayMetadata
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Store overlay metadata with CAS semantics (upsert).
  ## If record exists, uses existing token for CAS. If
  ## get fails (any error), uses token=0 (insert mode).
  ##

  ?await self.metaDs.tryPut(
    KVRecord[OverlayMetadata].init(?overlayKey(treeCid), meta),
    maxRetries = 3,
    proc(
        failed: seq[KVRecord[OverlayMetadata]]
    ): Future[?!seq[KVRecord[OverlayMetadata]]] {.async: (raises: [CancelledError]).} =
      # Refetch with current tokens, then update values
      var records = ?await self.metaDs.get(failed.mapIt(it.key), OverlayMetadata)
      records[0].val = meta # we're only getting a single record
      success records
    ,
  )

  trace "Overlay metadata stored", treeCid = treeCid, status = meta.status
  success()

proc getOverlayMetadata*(
    self: RepoStore, treeCid: Cid
): Future[?!OverlayMetadata] {.async: (raises: [CancelledError]).} =
  ## Get overlay metadata for a dataset.
  ##

  let meta = ?await self.metaDs.get(?overlayKey(treeCid), OverlayMetadata)
  trace "OverlayMetadata loaded", treeCid = treeCid, status = meta.val.status

proc deleteOverlayMetadata*(
    self: RepoStore, treeCid: Cid
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Delete overlay metadata (idempotent - returns success
  ## on any get error).
  ##

  ?await self.metaDs.delete(?await self.metaDs.get(?overlayKey(treeCid)))
  trace "Overlay metadata deleted", treeCid = treeCid
  success()

# func toCid[T](record: Record[T]): ?!Cid =
#   success ?Cid.init(record.key.value).mapFailure

# proc listOverlays*(
#     self: RepoStore
# ): Future[?!SafeAsyncIter[Cid]] {.async: (raises: [CancelledError]).} =
#   ## List all overlay CIDs.
#   ##

#   let
#     queryKey = ?overlayQueryKey()
#     iter = ?(await query[OverlayMetadata](self.metaDs, Query.init(queryKey)))

#   proc mapCids(
#       iterRes: ?!(?Record[OverlayMetadata])
#   ): Future[?!Cid] {.async: (raises: [CancelledError]).} =
#     if maybeRecord =? iterRes and record =? maybeRecord:
#       return success ?record.toCid
#     else:
#       return
#         failure(newException(ArchivistError, "Unable to construct Cid from record"))

#   let safeQueryIter = iter.toSafeAsyncIter()
#   success map[?Record[OverlayMetadata], Cid](safeQueryIter, mapCids)

# proc listOverlaysInState*(
#     self: RepoStore, status: OverlayStatus
# ): Future[?!SafeAsyncIter[Cid]] {.async: (raises: [CancelledError]).} =
#   ## List all overlay CIDs by status.
#   ##

#   let
#     queryKey = ?overlayQueryKey()
#     iter = ?(await query[OverlayMetadata](self.metaDs, Query.init(queryKey)))

#   let safeQueryIter = iter.toSafeAsyncIter()

#   proc filterBytStatus(
#       iterRes: ?!(?Record[OverlayMetadata])
#   ): Future[?(?!Cid)] {.async: (raises: [CancelledError]).} =
#     if maybeRecord =? iterRes and record =? maybeRecord:
#       if record.val.status == status:
#         without cid =? record.toCid, err:
#           trace "Unable to construct Cid from key", error = err.msg
#           return none(?!Cid)

#         return some(success(cid))

#     return none(?!Cid)

#   success await mapFilter[?Record[OverlayMetadata], Cid](
#     safeQueryIter, filterBytStatus, finishOnErr = false
#   )

# proc listOverlaysByExpiry*(
#     self: RepoStore, limit: int, offset: int
# ): Future[?!seq[(Cid, OverlayMetadata)]] {.async: (raises: [CancelledError]).} =
#   ## List overlays sorted by expiry time (ascending).
#   ##

#   let
#     queryKey = ?overlayQueryKey()
#     iter =
#       ?(
#         await query[OverlayMetadata](
#           self.metaDs, Query.init(queryKey, limit = limit, offset = offset)
#         )
#       )

#   proc mapRecord(
#       iterRes: ?!(?Record[OverlayMetadata])
#   ): Future[?(?!(Cid, OverlayMetadata))] {.async: (raises: [CancelledError]).} =
#     if maybeRecord =? iterRes and record =? maybeRecord:
#       without cid =? record.toCid, err:
#         trace "Unable to construct Cid from key", error = err.msg
#         return none(?!(Cid, OverlayMetadata))

#     return none(?!(Cid, OverlayMetadata))

#   let metadata = (
#     ?await collect(
#       await mapFilter[?Record[OverlayMetadata], (Cid, OverlayMetadata)](
#         iter.toSafeAsyncIter(), mapRecord
#       )
#     )
#   )
#   # Sort by expiry (ascending - earliest expiry first)
#   .sorted(
#     func (a, b: (Cid, OverlayMetadata)): int =
#       cmp(a[1].expiry, b[1].expiry)
#   )

#   success metadata
