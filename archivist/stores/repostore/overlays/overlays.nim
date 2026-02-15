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
import std/oids
import std/strutils
import std/sugar

import pkg/chronos
import pkg/kvstore
import pkg/libp2p/[cid, multihash, multicodec]
import pkg/stew/bitseqs
import pkg/results
import pkg/questionable
import pkg/questionable/results

import ./coders
import ../types
import ../operations
import ../../keyutils
import ../../../clock
import ../../../archivisttypes

import ../../queryiterhelper

import ../../../utils
import ../../../errors
import ../../../logutils

export coders

logScope:
  topics = "archivist repostore overlays"

const DefaultTmpOverlayTtl = 3.days # Default ttl for tmp overlays

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
  success meta.val

proc deleteOverlayMetadata*(
    self: RepoStore, treeCid: Cid
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Delete overlay metadata
  ##

  ?await self.metaDs.delete(?await self.metaDs.get(?overlayKey(treeCid)))
  trace "Overlay metadata deleted", treeCid = treeCid
  success()

func toCid(key: Key): ?!Cid =
  success ?Cid.init(key.value).mapFailure

proc listOverlays*(
    self: RepoStore
): Future[?!SafeAsyncIter[Cid]] {.async: (raises: [CancelledError]).} =
  ## List all overlay CIDs.
  ##

  let
    queryKey = ?overlayQueryKey()
    iter = ?(await query(self.metaDs, Query.init(queryKey), OverlayMetadata))

  proc mapCids(
      iterRes: ?!(?KVRecord[OverlayMetadata])
  ): Future[?(?!Cid)] {.async: (raises: [CancelledError]).} =
    if maybeRecord =? iterRes and record =? maybeRecord:
      without cid =? record.key.toCid, err:
        trace "Unable to construct Cid from key", error = err.msg
        return none(?!Cid)
      return some(success(cid))
    return none(?!Cid)

  let safeQueryIter = iter.toSafeAsyncIter()
  success await mapFilter[?KVRecord[OverlayMetadata], Cid](safeQueryIter, mapCids)

proc listOverlaysInState*(
    self: RepoStore, status: OverlayStatus
): Future[?!SafeAsyncIter[Cid]] {.async: (raises: [CancelledError]).} =
  ## List all overlay CIDs by status.
  ##

  let
    queryKey = ?overlayQueryKey()
    iter = ?(await query(self.metaDs, Query.init(queryKey), OverlayMetadata))

  let safeQueryIter = iter.toSafeAsyncIter()

  proc filterBytStatus(
      iterRes: ?!(?KVRecord[OverlayMetadata])
  ): Future[?(?!Cid)] {.async: (raises: [CancelledError]).} =
    if maybeRecord =? iterRes and record =? maybeRecord:
      if record.val.status == status:
        without cid =? record.key.toCid, err:
          trace "Unable to construct Cid from key", error = err.msg
          return none(?!Cid)

        return some(success(cid))

    return none(?!Cid)

  success await mapFilter[?KVRecord[OverlayMetadata], Cid](
    safeQueryIter, filterBytStatus, finishOnErr = false
  )

proc listOverlaysByExpiry*(
    self: RepoStore, limit: int, offset: int
): Future[?!seq[(Cid, OverlayMetadata)]] {.async: (raises: [CancelledError]).} =
  ## List overlays sorted by expiry time (ascending).
  ##

  let
    queryKey = ?overlayQueryKey()
    iter =
      ?(
        await query(
          self.metaDs,
          Query.init(queryKey, limit = limit, offset = offset),
          OverlayMetadata,
        )
      )

  proc mapRecord(
      iterRes: ?!(?KVRecord[OverlayMetadata])
  ): Future[?(?!(Cid, OverlayMetadata))] {.async: (raises: [CancelledError]).} =
    if maybeRecord =? iterRes and record =? maybeRecord:
      without cid =? record.key.toCid, err:
        trace "Unable to construct Cid from key", error = err.msg
        return none(?!(Cid, OverlayMetadata))

      return (success((cid, record.val))).some

  let metadata = (
    ?await collect(
      await mapFilter[?KVRecord[OverlayMetadata], (Cid, OverlayMetadata)](
        iter.toSafeAsyncIter(), mapRecord
      )
    )
  )
  # Sort by expiry (ascending - earliest expiry first)
  .sorted(
    func (a, b: (Cid, OverlayMetadata)): int =
      cmp(a[1].expiry, b[1].expiry)
  )

  success metadata

proc createOrUpdateOverlay*(
    self: RepoStore,
    treeCid: Cid,
    status = OverlayStatus.none,
    blocks = BitSeq.init(0),
    expiry = ZeroSeconds,
): Future[?!void] {.async: (raises: [CancelledError]).} =
  without var overlay =? (await self.getOverlayMetadata(treeCid)), err:
    if not (err of KVStoreKeyNotFound):
      trace "Error fetching overlay metadata for update",
        treeCid = treeCid, error = err.msg
      return failure(err)
    overlay = OverlayMetadata()

  overlay.blocks.combineSafe(blocks)
  overlay.status = status |? overlay.status

  let expiryTime =
    if expiry == ZeroSeconds:
      self.clock.now() + self.overlayTtl
    else:
      expiry

  overlay.expiry = expiryTime

  await self.putOverlayMetadata(treeCid, overlay)

proc createTmpOverlay*(
    self: RepoStore, expiry = ZeroSeconds
): Future[?!Cid] {.async: (raises: [CancelledError]).} =
  let
    oid = genOid()
    oidStr = $oid # 24-char hex string
    mhash =
      ?MultiHash.digest($Sha256HashCodec, oidStr.toOpenArrayByte(0, oidStr.high)).mapFailure
    tmpTreeCid = ?Cid.init(CIDv1, BlockCodec, mhash).mapFailure

  let expiryTime =
    if expiry == ZeroSeconds:
      self.clock.now() + self.overlayTtl
    else:
      expiry

  ?await self.putOverlayMetadata(
    tmpTreeCid,
    OverlayMetadata(status: Storing, expiry: expiryTime, blocks: BitSeq.init(0)),
  )

  success tmpTreeCid

proc dropOverlay*(
    self: RepoStore, treeCid: Cid
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Drop an overlay and delete all attached blocks.
  ##
  ## Queries all leaf records under /meta/leafs/{treeCid}/*, calls
  ## delLeafBlockMetadata to decrement refcounts and delete blocks at
  ## refCount=0, then deletes the overlay metadata record.
  ##
  ## Uses a runtime lock to prevent concurrent deletions of the same
  ## overlay. Returns success if deletion is already in progress.
  ##

  logScope:
    treeCid = treeCid

  if treeCid in self.deletingLock:
    trace "Overlay deletion already in progress, skipping"
    return success()

  self.deletingLock.incl(treeCid)
  defer:
    self.deletingLock.excl(treeCid)

  trace "Dropping overlay and cleaning up blocks"

  if err =?
      (await self.createOrUpdateOverlay(treeCid, status = Deleting.some)).errorOption:
    error "Unable to mark overlay as deleting", exc = err.msg
    return failure(err)

  # Query all leaf records for this tree
  let
    queryKey = ?blockLeafQueryKey(treeCid)
    iter = ?(await query(self.metaDs, Query.init(queryKey), LeafMetadata))

  # Extract indices from the leaf keys
  var indices: seq[Natural]
  for recordFut in iter:
    if record =? ?catch(?(await recordFut)):
      # Key format: /meta/leafs/{treeCid}/{index}
      # Extract index from last namespace segment
      let indexStr = record.key.value
      without idx =? parseInt(indexStr).catch, err:
        return failure(
          newException(
            ValueError, "Invalid index in key: " & indexStr & " - " & err.msg
          )
        )
      indices.add(idx.Natural)

  # Delete leaf metadata and decrement refcounts (two-phase atomic)
  if indices.len > 0:
    ?await delLeafBlockMetadata(self, treeCid, indices)
    trace "Deleted leaf metadata and updated refcounts", count = indices.len

  # Delete overlay metadata
  ?await self.deleteOverlayMetadata(treeCid)
  trace "Overlay dropped successfully"

  success()

proc finalizeOverlay*(
    self: RepoStore,
    tmpCid, realTreeCid: Cid,
    status = OverlayStatus.none,
    expiry = ZeroSeconds,
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Promote a temp overlay to a real overlay.
  ##
  ## Moves all leaf records from /meta/leafs/{tmpCid}/* to
  ## /meta/leafs/{realTreeCid}/* using a native key-prefix move,
  ## then moves the overlay metadata record.
  ## Block metadata is unchanged (keyed by blkCid, not treeCid).
  ##

  logScope:
    tmpCid = tmpCid
    realTreeCid = realTreeCid

  trace "Finalizing temp overlay"

  # Move leaf records: /meta/leafs/{tmpCid}/* -> /meta/leafs/{realTreeCid}/*
  let
    oldLeafPrefix = ?(BlockLeafKey / $tmpCid)
    newLeafPrefix = ?(BlockLeafKey / $realTreeCid)

  ?await self.metaDs.moveKeysAtomic(oldLeafPrefix, newLeafPrefix)

  # Move overlay metadata (single record — use put+delete)
  var meta = ?await self.getOverlayMetadata(tmpCid)

  let expiryTime =
    if expiry == ZeroSeconds:
      self.clock.now() + self.overlayTtl
    else:
      expiry

  meta.expiry = expiryTime
  meta.status = status |? meta.status

  ?await self.putOverlayMetadata(realTreeCid, meta)
  ?await self.deleteOverlayMetadata(tmpCid)

  trace "Temp overlay finalized successfully"
  success()

proc withOverlay*[T](
    self: RepoStore,
    treeCid: Cid,
    status = OverlayStatus.none,
    expiry = ZeroSeconds,
    body: proc(): Future[?!T] {.closure, gcsafe, async: (raises: [CancelledError]).},
): Future[?!T] {.async: (raises: [CancelledError]).} =
  ## Create or update overlay with initial state and expiry.
  ##

  logScope:
    treeCid = treeCid
    status = status

  trace "Starting overlay operation"
  if initErr =? (
    await self.createOrUpdateOverlay(treeCid, status, BitSeq.init(0), expiry)
  ).errorOption:
    error "Unable to create/update overlay metadata", exc = initErr.msg
    return failure(initErr)

  let
    bodyRes = await body()
    finalState = if bodyRes.isOk: Completed.some else: Failure.some

  if finalErr =? (
    await self.createOrUpdateOverlay(treeCid, finalState, BitSeq.init(0), expiry)
  ).errorOption:
    error "Unable to set overlay final state", exc = finalErr.msg
    return failure(finalErr)

  trace "Overlay operation completed", finalState

  return bodyRes

proc withTmpOverlay*(
    self: RepoStore,
    body: proc(tmpCid: Cid): Future[?!Cid] {.
      closure, gcsafe, async: (raises: [CancelledError])
    .},
): Future[?!Cid] {.async: (raises: [CancelledError]).} =
  ## Create a temporary overlay, run body, finalize or drop.
  ## Body must return ?!Cid (the real treeCid).
  ##

  trace "Starting temporary overlay operation"

  var completed = false

  without tmpCid =? (await self.createTmpOverlay()), err:
    error "Unable to create temporary overlay", exc = err.msg
    return failure(err)

  trace "Temporary overlay created", tmpCid

  defer:
    if not completed:
      if dropErr =? (await noCancel self.dropOverlay(tmpCid)).errorOption:
        error "Unable to drop tmp overlay on error", exc = dropErr.msg

  let bodyRes = await body(tmpCid)

  without realCid =? bodyRes, err:
    error "Body failed to return real tree CID", error = err.msg
    return failure(err)

  completed = true
  trace "Body completed successfully, finalizing overlay", realCid, tmpCid
  if finalErr =? (
    await self.finalizeOverlay(tmpCid, realCid, status = OverlayStatus.Completed.some)
  ).errorOption:
    error "Unable to finalize tmp overlay", exc = finalErr.msg
    return failure(finalErr)

  bodyRes
