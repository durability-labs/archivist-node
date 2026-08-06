{.push raises: [].}

import std/tables
import std/sequtils

import pkg/chronos
import pkg/kvstore
import pkg/libp2p/cid
import pkg/questionable
import pkg/questionable/results

import ./types
import ./overlays/coders

import ../keyutils

func overlayRejectsWrites*(status: OverlayStatus): bool =
  status == Deleting or status == Finalizing

proc markDeleting*(
    self: RepoStore, treeCid: Cid
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Mark overlay as Deleting with CAS guard against Finalizing.
  ## Idempotent if already Deleting. Fails if overlay is Finalizing.

  let key = ?overlayKey(treeCid)
  self.overlayCache.del(key)

  without var record =? (await self.metaDs.get(key, OverlayMetadata)), err:
    if not (err of KVStoreKeyNotFound):
      return failure(err)
    return failure(newException(OverlayDeletingError, "Overlay not found"))

  if record.val.status == Finalizing:
    return failure(
      newException(OverlayDeletingError, "Cannot mark Deleting: overlay is Finalizing")
    )

  if record.val.status == Deleting:
    return success()

  record.val.status = Deleting
  var cached = record.val

  ?await self.metaDs.tryPut(
    record,
    maxRetries = 10,
    proc(
        failed: seq[KVRecord[OverlayMetadata]]
    ): Future[?!seq[KVRecord[OverlayMetadata]]] {.async: (raises: [CancelledError]).} =
      var records = ?await self.metaDs.get(failed.mapIt(it.key), OverlayMetadata)
      for rec in records.mitems:
        if rec.val.status == Finalizing:
          return failure(
            newException(
              OverlayDeletingError, "Cannot mark Deleting: overlay is Finalizing"
            )
          )
        rec.val.status = Deleting
      cached = records[0].val
      success records
    ,
  )

  self.overlayCache[key] = cached
  success()

proc markFinalizing*(
    self: RepoStore, treeCid: Cid
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Mark overlay as Finalizing with CAS guard against Deleting.
  ## Idempotent if already Finalizing. Fails if overlay is Deleting.

  let key = ?overlayKey(treeCid)
  self.overlayCache.del(key)

  without var record =? (await self.metaDs.get(key, OverlayMetadata)), err:
    if not (err of KVStoreKeyNotFound):
      return failure(err)
    return
      failure(newException(OverlayDeletingError, "Overlay not found for finalization"))

  if record.val.status == Deleting:
    return failure(
      newException(OverlayDeletingError, "Cannot mark Finalizing: overlay is Deleting")
    )

  if record.val.status == Finalizing:
    return success()

  record.val.status = Finalizing
  var cached = record.val

  ?await self.metaDs.tryPut(
    record,
    maxRetries = 10,
    proc(
        failed: seq[KVRecord[OverlayMetadata]]
    ): Future[?!seq[KVRecord[OverlayMetadata]]] {.async: (raises: [CancelledError]).} =
      var records = ?await self.metaDs.get(failed.mapIt(it.key), OverlayMetadata)
      for rec in records.mitems:
        if rec.val.status == Deleting:
          return failure(
            newException(
              OverlayDeletingError, "Cannot mark Finalizing: overlay is Deleting"
            )
          )
        rec.val.status = Finalizing
      cached = records[0].val
      success records
    ,
  )

  self.overlayCache[key] = cached
  success()
