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
import ../../../rng

export coders

logScope:
  topics = "archivist repostore overlays"

const DefaultTmpOverlayTtl = 3.days # Default ttl for tmp overlays

proc mergeOverlay(
    self: RepoStore,
    overlay: var OverlayMetadata,
    status: ?OverlayStatus,
    blocks: BitSeq,
    expiry: SecondsSince1970,
    manifestCid: ?Cid,
) =
  ## Apply merge logic: OR-combine blocks, fallback status, conditional fields.
  ##

  overlay.blocks.combineSafe(blocks)
  overlay.status = status |? overlay.status

  if manifestCid.isSome:
    overlay.manifestCid = manifestCid

  if expiry != ZeroSeconds:
    overlay.expiry = expiry
  elif overlay.expiry == ZeroSeconds:
    overlay.expiry = self.clock.now() + self.overlayTtl

proc putOverlayMetadata*(
    self: RepoStore,
    treeCid: Cid,
    status: ?OverlayStatus = OverlayStatus.none,
    blocks = BitSeq.init(0),
    expiry = ZeroSeconds,
    manifestCid: ?Cid = Cid.none,
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Store overlay metadata with CAS semantics (upsert).
  ## On conflict, re-reads current state and merges with provided values
  ## instead of blindly overwriting.
  ##
  ## Parameters:
  ## - status: OverlayStatus to set (uses |? fallback if not provided)
  ## - blocks: BitSeq to OR-combine with existing
  ## - expiry: Expiry time (sets if non-zero, otherwise keeps existing or sets default)
  ## - manifestCid: Optional manifest CID to set
  ##

  let key = ?overlayKey(treeCid)

  # Read full KVRecord (preserving CAS token) for correct first attempt
  without var record =? (await self.metaDs.get(key, OverlayMetadata)), err:
    if not (err of KVStoreKeyNotFound):
      trace "Error fetching overlay metadata for put",
        treeCid = treeCid, error = err.msg
      return failure(err)
    record = KVRecord[OverlayMetadata].init(key, OverlayMetadata())

  self.mergeOverlay(record.val, status, blocks, expiry, manifestCid)

  ?await self.metaDs.tryPut(
    record,
    maxRetries = 10,
    proc(
        failed: seq[KVRecord[OverlayMetadata]]
    ): Future[?!seq[KVRecord[OverlayMetadata]]] {.async: (raises: [CancelledError]).} =
      var records = ?await self.metaDs.get(failed.mapIt(it.key), OverlayMetadata)
      self.mergeOverlay(records[0].val, status, blocks, expiry, manifestCid)
      success records
    ,
  )

  trace "Overlay metadata stored", treeCid = treeCid, status = record.val.status
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

proc createTmpOverlay*(
    self: RepoStore, expiry = ZeroSeconds
): Future[?!Cid] {.async: (raises: [CancelledError]).} =
  var randomBytes: array[32, byte]
  Rng.instance[].generate(randomBytes)
  let
    mhash = ?MultiHash.digest($Sha256HashCodec, randomBytes).mapFailure
    tmpTreeCid = ?Cid.init(CIDv1, BlockCodec, mhash).mapFailure

  let expiryTime =
    if expiry == ZeroSeconds:
      self.clock.now() + self.overlayTtl
    else:
      expiry

  ?await self.putOverlayMetadata(
    tmpTreeCid,
    status = OverlayStatus.Storing.some,
    blocks = BitSeq.init(0),
    expiry = expiryTime,
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

  if err =? (await self.putOverlayMetadata(treeCid, status = Deleting.some)).errorOption:
    error "Unable to mark overlay as deleting", exc = err.msg
    return failure(err)

  # Read overlay metadata to get manifestCid before deletion
  var manifestCid: ?Cid
  if meta =? (await self.getOverlayMetadata(treeCid)):
    manifestCid = meta.manifestCid

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

  # Delete manifest block if tracked
  if cid =? manifestCid:
    let skipped = ?await self.tryDeleteBlocks(cid)
    if skipped.len > 0:
      warn "Manifest block was not deleted", manifestCid = cid

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
  ## Atomically moves all leaf records and overlay metadata from
  ## tmpCid to realTreeCid in a single transaction, then updates
  ## the overlay metadata (expiry/status) as a separate CAS operation.
  ##
  ## Block metadata is unchanged (keyed by blkCid, not treeCid).
  ##

  logScope:
    tmpCid = tmpCid
    realTreeCid = realTreeCid

  trace "Finalizing temp overlay"

  # Atomically move both leaf records and overlay metadata
  if err =? (
    await self.metaDs.moveKeysAtomic(
      @[
        (?(BlockLeafKey / $tmpCid), ?(BlockLeafKey / $realTreeCid)),
        (?overlayKey(tmpCid), ?overlayKey(realTreeCid)),
      ]
    )
  ).errorOption:
    if err of KVConflictError:
      # Destination already has the data (content-addressed guarantee).
      # Nothing was moved — tmp is still intact. Drop it cleanly.
      trace "Overlay already exists at realTreeCid, dropping tmp"
      if dropErr =? (
        await noCancel self.metaDs.dropPrefix(
          @[?(BlockLeafKey / $tmpCid), ?overlayKey(tmpCid)]
        )
      ).errorOption:
        error "Unable to drop tmp overlay after finalize conflict", exc = dropErr.msg
      return success()
    error "Unable to move overlay metadata atomically", exc = err.msg
    return failure(err)

  # Update overlay metadata (expiry/status) at the new location.
  # This is a separate CAS operation — if it fails, data is safe
  # (everything is already at realTreeCid) and retry will find it.
  let expiryTime =
    if expiry == ZeroSeconds:
      self.clock.now() + self.overlayTtl
    else:
      expiry

  if err =? (
    await self.putOverlayMetadata(realTreeCid, status = status, expiry = expiryTime)
  ).errorOption:
    error "Unable to update overlay metadata after finalization", exc = err.msg
    return failure(err)

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
  if initErr =?
      (await self.putOverlayMetadata(treeCid, status, BitSeq.init(0), expiry)).errorOption:
    error "Unable to create/update overlay metadata", exc = initErr.msg
    return failure(initErr)

  let
    bodyRes = await body()
    finalState = if bodyRes.isOk: Completed.some else: Failure.some

  if finalErr =? (
    await self.putOverlayMetadata(treeCid, finalState, BitSeq.init(0), expiry)
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
      # Tmp overlays have no refcount associations yet — safe to drop directly
      if dropErr =? (
        await noCancel self.metaDs.dropPrefix(
          @[?(BlockLeafKey / $tmpCid), ?overlayKey(tmpCid)]
        )
      ).errorOption:
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
