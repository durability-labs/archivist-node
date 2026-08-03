## Overlay metadata operations - storing, retrieving, and listing dataset overlays

{.push raises: [].}

import std/algorithm
import std/tables

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
import ../treeops
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

proc putOverlay*(
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
  self.overlayCache.del(key)

  # Read full KVRecord (preserving CAS token) for correct first attempt
  without var record =? (await self.metaDs.get(key, OverlayMetadata)), err:
    if not (err of KVStoreKeyNotFound):
      trace "Error fetching overlay metadata for put",
        treeCid = treeCid, error = err.msg
      return failure(err)
    record = KVRecord[OverlayMetadata].init(key, OverlayMetadata())

  self.mergeOverlay(record.val, status, blocks, expiry, manifestCid)
  var cachedOverlay = record.val
  ?await self.metaDs.tryPut(
    record,
    maxRetries = 10,
    proc(
        failed: seq[KVRecord[OverlayMetadata]]
    ): Future[?!seq[KVRecord[OverlayMetadata]]] {.async: (raises: [CancelledError]).} =
      var records = ?await self.metaDs.get(failed.mapIt(it.key), OverlayMetadata)
      self.mergeOverlay(records[0].val, status, blocks, expiry, manifestCid)
      cachedOverlay = records[0].val
      success records
    ,
  )

  # cache the final merged overlay
  self.overlayCache[key] = cachedOverlay
  trace "Overlay metadata stored", treeCid = treeCid, status = cachedOverlay.status
  success()

proc getOverlay*(
    self: RepoStore, treeCid: Cid
): Future[?!OverlayMetadata] {.async: (raises: [CancelledError]).} =
  ## Get overlay metadata for a dataset.
  ##

  let key = ?overlayKey(treeCid)
  self.overlayCache.withValue(key, value):
    return success value[]

  let meta = ?await self.metaDs.get(key, OverlayMetadata)
  trace "OverlayMetadata loaded", treeCid = treeCid, status = meta.val.status

  success meta.val

proc deleteOverlay*(
    self: RepoStore, treeCid: Cid
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Delete overlay metadata
  ##

  let key = ?overlayKey(treeCid)
  self.overlayCache.del(key)

  ?await self.metaDs.delete(?await self.metaDs.get(key))

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

  ?await self.putOverlay(
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

  trace "Dropping overlay and cleaning up blocks"

  without overlay =? (await self.getOverlay(treeCid)), err:
    if err of KVStoreKeyNotFound:
      trace "Overlay already deleted", treeCid
      return success()
    return failure(err)

  if overlay.status == Finalizing:
    return failure(newException(OverlayDeletingError, "Overlay is finalizing"))

  if err =? (await self.markDeleting(treeCid)).errorOption:
    error "Unable to mark overlay as deleting", exc = err.msg
    return failure(err)

  await self.deletingLock.drain(treeCid)

  while true:
    without overlay =? (await self.getOverlay(treeCid)), err:
      if err of KVStoreKeyNotFound:
        trace "Overlay already deleted", treeCid
        break
      warn "Overlay missing", treeCid, err = err.msg
      return failure(err)

    var indices: seq[Natural]
    for i in 0 ..< overlay.blocks.len:
      if overlay.blocks[i.Natural]:
        indices.add(i.Natural)

    # Delete leaf metadata and decrement refcounts (two-phase atomic)
    if indices.len == 0:
      break

    ?await self.delLeafBlockMetadata(treeCid, indices)
    trace "Deleted leaf metadata and updated refcounts", count = indices.len

  ?await self.delTreeNodes(treeCid)

  # Detach manifest and try to delete if refcount reaches 0
  ?await self.dropManifest(treeCid)

  # Delete overlay metadata
  ?await self.deleteOverlay(treeCid)

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
  ## Atomically moves leaf records, tree records, and overlay metadata from
  ## tmpCid to realTreeCid. The tmp overlay is marked Finalizing before
  ## the move to reject concurrent writers. After the move, the overlay
  ## at realTreeCid carries the final status (set via a separate CAS).
  ##
  ## Block metadata is unchanged (keyed by blkCid, not treeCid).
  ##

  logScope:
    tmpCid = tmpCid
    realTreeCid = realTreeCid

  trace "Finalizing temp overlay"

  let
    tmpOverlayKey = ?overlayKey(tmpCid)
    overlayKey = ?overlayKey(realTreeCid)

  defer:
    self.overlayCache.del(tmpOverlayKey)

  # Read original status, mark Finalizing (rejects new writers), drain in-flight writers.
  let tmpRecord = ?await self.metaDs.get(tmpOverlayKey, OverlayMetadata)
  let tmpOrigStatus = tmpRecord.val.status
  ?await self.markFinalizing(tmpCid)
  await self.deletingLock.drain(tmpCid)

  let expiryTime =
    if expiry == ZeroSeconds:
      self.clock.now() + self.overlayTtl
    else:
      expiry

  # Atomically move leaf records, tree records, and overlay metadata.
  # The overlay carries Finalizing status during the move.
  if err =? (
    await self.metaDs.moveKeysAtomic(
      @[
        (?(BlockLeafKey / $tmpCid), ?(BlockLeafKey / $realTreeCid)),
        (?(TreeNodeKey / $tmpCid), ?(TreeNodeKey / $realTreeCid)),
        (tmpOverlayKey, overlayKey),
      ]
    )
  ).errorOption:
    if restoreErr =?
        (await noCancel self.putOverlay(tmpCid, status = tmpOrigStatus.some)).errorOption:
      error "Unable to restore tmp overlay after finalization failure",
        exc = restoreErr.msg
      return failure(restoreErr)
    error "Unable to move overlay metadata atomically", exc = err.msg
    return failure(err)

  # Set final status at realTreeCid. The overlay arrived as Finalizing,
  # so no writers can race. If this CAS fails, data is safe and the real
  # overlay is visible as Finalizing for retry or repair.
  let finalStatus = status |? tmpOrigStatus
  if err =? (
    await self.putOverlay(realTreeCid, status = finalStatus.some, expiry = expiryTime)
  ).errorOption:
    error "Unable to set final overlay status after finalization", exc = err.msg
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
  if err =? (await self.putOverlay(treeCid, status, BitSeq.init(0), expiry)).errorOption:
    error "Unable to create/update overlay metadata", exc = err.msg
    return failure(err)

  let
    bodyRes = await body()
    finalState = if bodyRes.isOk: Completed.some else: Failure.some

  if err =?
      (await self.putOverlay(treeCid, finalState, BitSeq.init(0), expiry)).errorOption:
    error "Unable to set overlay final state", exc = err.msg
    return failure(err)

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
      # Tmp overlays have no refcount associations yet - safe to drop directly
      if dropErr =? (await noCancel self.dropOverlay(tmpCid)).errorOption:
        error "Unable to drop tmp overlay on error", exc = dropErr.msg

  let bodyRes = await body(tmpCid)

  without realCid =? bodyRes, err:
    error "Body failed to return real tree CID", error = err.msg
    return failure(err)

  trace "Body completed successfully, finalizing overlay", realCid, tmpCid
  if finalErr =? (
    await self.finalizeOverlay(tmpCid, realCid, status = OverlayStatus.Completed.some)
  ).errorOption:
    error "Unable to finalize tmp overlay", exc = finalErr.msg
    return failure(finalErr)

  completed = true
  bodyRes
