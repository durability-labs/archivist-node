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
  ## Delete overlay metadata (idempotent - returns success
  ## on any get error).
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
  ): Future[?!Cid] {.async: (raises: [CancelledError]).} =
    if maybeRecord =? iterRes and record =? maybeRecord:
      return success ?record.key.toCid
    else:
      return
        failure(newException(ArchivistError, "Unable to construct Cid from record"))

  let safeQueryIter = iter.toSafeAsyncIter()
  success map[?KVRecord[OverlayMetadata], Cid](safeQueryIter, mapCids)

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
    status: OverlayStatus,
    blocks: BitSeq,
    expiry = DefaultOverlayTtl,
    manifest: ?Cid = Cid.none,
): Future[?!void] {.async: (raises: [CancelledError], raw: true).} =
  self.putOverlayMetadata(
    treeCid,
    OverlayMetadata(
      status: status,
      blocks: blocks,
      manifest: manifest,
      expiry: self.clock.now() + expiry.seconds,
    ),
  )

proc createTmpOverlay*(
    self: RepoStore, expiry = DefaultOverlayTtl
): Future[?!Cid] {.async: (raises: [CancelledError]).} =
  let
    oid = genOid()
    oidStr = $oid # 24-char hex string
    mhash =
      ?MultiHash.digest($Sha256HashCodec, oidStr.toOpenArrayByte(0, oidStr.high)).mapFailure
    tmpTreeCid = ?Cid.init(CIDv1, BlockCodec, mhash).mapFailure

  ?await self.putOverlayMetadata(
    tmpTreeCid,
    OverlayMetadata(
      status: OverlayStatus.Storing,
      manifest: Cid.none,
      expiry: self.clock.now() + expiry.seconds,
      blocks: BitSeq.init(0),
    ),
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

  logScope:
    treeCid = treeCid

  trace "Dropping overlay and cleaning up blocks"

  # Query all leaf records for this tree
  let
    queryKey = ?blockProofQueryKey(treeCid)
    iter = ?(await query(self.metaDs, Query.init(queryKey), LeafMetadata))
    leafRecords = ?await iter.fetchAll()

  trace "Found leaf records to delete", count = leafRecords.len

  # Extract indices from the leaf keys
  var indices: seq[Natural]
  for record in leafRecords:
    # Key format: /meta/leafs/{treeCid}/{index}
    # Extract index from last namespace segment
    let indexStr = record.key.value
    without idx =? parseInt(indexStr).catch, err:
      return failure(
        newException(ValueError, "Invalid index in key: " & indexStr & " - " & err.msg)
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
    self: RepoStore, tmpCid, realTreeCid: Cid
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

  # Move leaf records: /meta/leafs/{tmpCid}/* → /meta/leafs/{realTreeCid}/*
  let
    oldLeafPrefix = ?(BlockLeafKey / $tmpCid)
    newLeafPrefix = ?(BlockLeafKey / $realTreeCid)

  ?await self.metaDs.moveKeysAtomic(oldLeafPrefix, newLeafPrefix)

  # Move overlay metadata (single record — use put+delete)
  let meta = ?await self.getOverlayMetadata(tmpCid)
  ?await self.putOverlayMetadata(realTreeCid, meta)
  ?await self.deleteOverlayMetadata(tmpCid)

  trace "Temp overlay finalized successfully"
  success()
