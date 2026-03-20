## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/options
import std/sequtils
import std/sugar
import times

import pkg/taskpools
import pkg/stew/bitseqs
import pkg/questionable
import pkg/questionable/results
import pkg/chronos
import pkg/poseidon2
import pkg/ethers
import pkg/metrics except collect

import pkg/libp2p/[switch, multicodec, multihash]
import pkg/libp2p/stream/bufferstream

# TODO: remove once exported by libp2p
import pkg/libp2p/routing_record
import pkg/libp2p/signed_envelope

import ./metrics
import ./chunker
import ./slots
import ./clock
import ./blocktype as bt
import ./manifest
import ./merkletree
import ./stores
import ./blockexchange
import ./streams
import ./erasure
import ./discovery
import ./marketplace
import ./indexingstrategy
import ./utils
import ./errors
import ./logutils
import ./utils/asynciter
import ./utils/trackedfutures
import ./utils/poseidon2digest

export logutils

logScope:
  topics = "archivist node"

const
  DefaultFetchBatch = 10
  DefaultStoreBatch* = 1024 ## Number of blocks to batch when storing data
  MaxInFlightBatches = 4 ## Maximum concurrent batch flushes for bounded parallelism

type
  ArchivistNode* = object
    switch: Switch
    networkId: PeerId
    networkStore: NetworkStore
    repoStore: RepoStore
    engine: BlockExcEngine
    prover: ?Prover
    discovery: Discovery
    marketplace: ?MarketplaceNode
    taskpool: Taskpool
    trackedFutures: TrackedFutures
    # proofs/period metric:
    numProofs: int64

  ArchivistNodeRef* = ref ArchivistNode

  OnManifest* = proc(cid: Cid, manifest: Manifest): void {.gcsafe, raises: [].}
  BatchProc* = proc(blocks: seq[bt.Block]): Future[?!void] {.
    gcsafe, async: (raises: [CancelledError])
  .}

func switch*(self: ArchivistNodeRef): Switch =
  return self.switch

func blockStore*(self: ArchivistNodeRef): BlockStore =
  return self.networkStore

func engine*(self: ArchivistNodeRef): BlockExcEngine =
  return self.engine

func discovery*(self: ArchivistNodeRef): Discovery =
  return self.discovery

func ethAddress*(self: ArchivistNodeRef): ?ethers.Address =
  self.marketplace .? address

func marketplace*(self: ArchivistNodeRef): ?MarketplaceNode =
  self.marketplace

func `marketplace=`*(self: ArchivistNodeRef, marketplace: MarketplaceNode) =
  doAssert self.marketplace.isNone
  self.marketplace = some marketplace

proc fetchManifest*(
    self: ArchivistNodeRef, cid: Cid
): Future[?!Manifest] {.async: (raises: [CancelledError]).} =
  ## Fetch and decode a manifest block
  ##

  if err =? cid.isManifest.errorOption:
    return failure "CID has invalid content type for manifest {$cid}"

  trace "Retrieving manifest for cid", cid

  without blk =? await self.networkStore.getBlock(cid), err:
    trace "Error retrieve manifest block", cid, err = err.msg
    return failure err

  trace "Decoding manifest for cid", cid

  without manifest =? Manifest.decode(blk), err:
    trace "Unable to decode as manifest", err = err.msg
    return failure("Unable to decode as manifest")

  trace "Decoded manifest", cid

  return manifest.success

proc findPeer*(self: ArchivistNodeRef, peerId: PeerId): Future[?PeerRecord] {.async.} =
  ## Find peer using the discovery service from the given ArchivistNode
  ##
  return await self.discovery.findPeer(peerId)

proc connect*(
    self: ArchivistNodeRef, peerId: PeerId, addrs: seq[MultiAddress]
): Future[void] =
  self.switch.connect(peerId, addrs)

proc updateExpiry*(
    self: ArchivistNodeRef, manifest: Manifest, expiry: SecondsSince1970
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ?await self.repoStore.putOverlay(manifest.treeCid, expiry = expiry)
  return success()

proc updateExpiry*(
    self: ArchivistNodeRef, manifestCid: Cid, expiry: SecondsSince1970
): Future[?!void] {.async: (raises: [CancelledError]).} =
  without manifest =? await self.fetchManifest(manifestCid), error:
    trace "Unable to fetch manifest for cid", manifestCid
    return failure(error)

  await self.updateExpiry(manifest, expiry)

proc fetchBatched*(
    self: ArchivistNodeRef,
    cid: Cid,
    iter: Iter[int],
    batchSize = DefaultFetchBatch,
    onBatch: BatchProc = nil,
    fetchLocal = true,
): Future[?!void] {.async: (raises: [CancelledError]), gcsafe.} =
  ## Fetch blocks in batches of `batchSize`
  ##

  await self.repoStore.withOverlay(
    cid,
    status = Downloading.some,
    body = proc(): Future[?!void] {.closure, gcsafe, async: (raises: [CancelledError]).} =
      # When fetchLocal = false, fetch bitmap once to filter already-present blocks
      # in memory. This avoids O(N) per-block SQLite lookups (hasBlock ->
      # getBlocksBitmap) and replaces them with a single bitmap fetch upfront.
      # When fetchLocal = true we include all indices regardless, so no check needed.
      let bits =
        if not fetchLocal:
          ?await self.repoStore.getBlocksBitmap(cid)
        else:
          BitSeq.init(0)

      while not iter.finished:
        var batchIndices: seq[Natural]
        for i in 0 ..< batchSize:
          if not iter.finished:
            let idx = iter.next()
            # Include index if fetchLocal is set, or if it's not yet in the bitmap
            if fetchLocal or idx >= bits.len or not bits[idx]:
              batchIndices.add(idx.Natural)

        if batchIndices.len == 0:
          continue

        without blocks =? (await self.networkStore.getBlocks(cid, batchIndices)), err:
          trace "Some blocks failed to fetch", err = err.msg
          return failure(err)

        if blocks.len != batchIndices.len:
          return failure(
            "Some blocks failed to fetch (" & $(batchIndices.len - blocks.len) &
              " missing)"
          )

        if not onBatch.isNil and
            batchErr =? (await onBatch(blocks.mapIt(it[1]))).errorOption:
          return failure(batchErr)

      success(),
  )

proc fetchBatched*(
    self: ArchivistNodeRef,
    manifest: Manifest,
    batchSize = DefaultFetchBatch,
    onBatch: BatchProc = nil,
    fetchLocal = true,
): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
  ## Fetch manifest in batches of `batchSize`
  ##

  trace "Fetching blocks in batches of",
    size = batchSize, blocksCount = manifest.blocksCount

  let iter = Iter[int].new(0 ..< manifest.blocksCount)
  self.fetchBatched(manifest.treeCid, iter, batchSize, onBatch, fetchLocal)

proc fetchDatasetAsync*(
    self: ArchivistNodeRef, manifest: Manifest, fetchLocal = true
): Future[void] {.async: (raises: []).} =
  ## Asynchronously fetch a dataset in the background.
  ## This task will be tracked and cleaned up on node shutdown.
  ##
  try:
    if err =? (
      await self.fetchBatched(
        manifest = manifest, batchSize = DefaultFetchBatch, fetchLocal = fetchLocal
      )
    ).errorOption:
      error "Unable to fetch blocks", err = err.msg
  except CancelledError as exc:
    trace "Cancelled fetching blocks", exc = exc.msg

proc fetchDatasetAsyncTask*(self: ArchivistNodeRef, manifest: Manifest) =
  ## Start fetching a dataset in the background.
  ## The task will be tracked and cleaned up on node shutdown.
  ##
  proc run(): Future[void] {.async: (raises: []).} =
    try:
      if err =? (
        await self.fetchBatched(
          manifest = manifest, batchSize = DefaultFetchBatch, fetchLocal = false
        )
      ).errorOption:
        error "Unable to fetch dataset", err = err.msg
    except CancelledError as exc:
      trace "Dataset fetch cancelled", exc = exc.msg

  self.trackedFutures.track(run())

proc streamSingleBlock(
    self: ArchivistNodeRef, cid: Cid
): Future[?!LPStream] {.async: (raises: [CancelledError]).} =
  ## Streams the contents of a single block.
  ##
  trace "Streaming single block", cid = cid

  let stream = BufferStream.new()

  without blk =? (await self.networkStore.getBlock(cid)), err:
    return failure(err)

  proc streamOneBlock(): Future[void] {.async: (raises: []).} =
    try:
      defer:
        await stream.pushEof()
      await stream.pushData(blk.data)
    except CancelledError as exc:
      trace "Streaming block cancelled", cid, exc = exc.msg
    except LPStreamError as exc:
      trace "Unable to send block", cid, exc = exc.msg

  self.trackedFutures.track(streamOneBlock())
  LPStream(stream).success

proc streamEntireDataset(
    self: ArchivistNodeRef, manifest: Manifest, manifestCid: Cid
): Future[?!LPStream] {.async: (raises: [CancelledError]).} =
  ## Streams the contents of the entire dataset described by the manifest.
  ##
  trace "Retrieving blocks from manifest", manifestCid

  var jobs: seq[Future[void]]
  let stream = LPStream(StoreStream.new(self.networkStore, manifest, pad = false))
  if manifest.protected:
    # For protected manifests, erasure.decode owns the overlay lifecycle
    # via its own withOverlay(treeCid, Storing) call. It also fetches all
    # blocks via networkStore.getBlock, so no separate fetch job is needed.
    proc erasureJob(): Future[void] {.async: (raises: []).} =
      try:
        let erasure = Erasure.new(
          self.networkStore, self.repoStore, leoEncoderProvider, leoDecoderProvider,
          self.taskpool,
        )

        if err =? (await erasure.decode(manifest)).errorOption:
          error "Unable to erasure decode manifest", manifestCid, exc = err.msg
          return
      except CatchableError as exc:
        trace "Error erasure decoding manifest", manifestCid, exc = exc.msg

    jobs.add(erasureJob())
  else:
    proc fetchJob(): Future[void] {.async: (raises: []).} =
      try:
        if err =? (
          await self.fetchBatched(
            manifest = manifest, batchSize = DefaultFetchBatch, fetchLocal = false
          )
        ).errorOption:
          error "Unable to fetch blocks", err = err.msg
      except CancelledError as exc:
        trace "Cancelled fetching blocks", exc = exc.msg

    jobs.add(fetchJob())

  # Monitor stream completion and cancel background jobs when done
  proc monitorStream() {.async: (raises: []).} =
    try:
      await stream.join()
    except CancelledError as exc:
      warn "Stream cancelled", exc = exc.msg
    finally:
      await noCancel allFutures(jobs.mapIt(it.cancelAndWait))

  self.trackedFutures.track(monitorStream())

  # Retrieve all blocks of the dataset sequentially from the local store or network
  trace "Creating store stream for manifest", manifestCid

  stream.success

proc retrieve*(
    self: ArchivistNodeRef, cid: Cid, local: bool = true
): Future[?!LPStream] {.async: (raises: [CancelledError]).} =
  ## Retrieve by Cid a single block or an entire dataset described by manifest
  ##

  if local and not await (cid in self.networkStore):
    return failure((ref BlockNotFoundError)(msg: "Block not found in local store"))

  without manifest =? (await self.fetchManifest(cid)), err:
    if err of AsyncTimeoutError:
      return failure(err)

    return await self.streamSingleBlock(cid)

  # track manifest CID in overlay for cleanup
  ?await self.repoStore.putOverlay(manifest.treeCid, manifestCid = cid.some)

  await self.streamEntireDataset(manifest, cid)

proc deleteSingleBlock(
    self: ArchivistNodeRef, cid: Cid
): Future[?!void] {.async: (raises: [CancelledError]).} =
  if err =? (await self.networkStore.delBlock(cid)).errorOption:
    error "Error deleting block", cid, err = err.msg
    return failure(err)

  trace "Deleted block", cid
  return success()

proc deleteEntireDataset(
    self: ArchivistNodeRef, cid: Cid
): Future[?!void] {.async: (raises: [CancelledError]).} =
  # Deletion is a strictly local operation
  var store = self.networkStore.localStore

  without manifestBlock =? await store.getBlock(cid), err:
    return failure(err)

  without manifest =? Manifest.decode(manifestBlock), err:
    return failure(err)

  if err =? (await self.repoStore.dropOverlay(manifest.treeCid)).errorOption:
    error "Error dropping manifest overlay", cid, err = err.msg
    return failure(err)

  if err =? (await store.delBlock(cid)).errorOption:
    warn "Manifest block already removed", cid, err = err.msg

  success()

proc delete*(
    self: ArchivistNodeRef, cid: Cid
): Future[?!void] {.async: (raises: [CatchableError]).} =
  ## Deletes a whole dataset, if Cid is a Manifest Cid, or a single block, if Cid a block Cid,
  ## from the underlying block store. This is a strictly local operation.
  ##
  ## Missing blocks in dataset deletes are ignored.
  ##

  without isManifest =? cid.isManifest, err:
    trace "Bad content type for CID:", cid = cid, err = err.msg
    return failure(err)

  if not isManifest:
    return await self.deleteSingleBlock(cid)

  await self.deleteEntireDataset(cid)

proc store*(
    self: ArchivistNodeRef,
    stream: LPStream,
    filename: ?string = string.none,
    mimetype: ?string = string.none,
    blockSize = DefaultBlockSize,
    storeBatchSize = DefaultStoreBatch,
): Future[?!Cid] {.async: (raises: [CancelledError]).} =
  ## Save stream contents as dataset with given blockSize
  ## to nodes's BlockStore, and return Cid of its manifest
  ##
  ## Blocks are batched for efficient storage (storeBatchSize blocks per batch).
  ##
  info "Storing data"

  let
    hcodec = Sha256HashCodec
    dataCodec = BlockCodec
    chunker = LPStreamChunker.new(stream, chunkSize = blockSize)

  defer:
    await stream.close()

  proc flushBatch(
      tmpCid: Cid, batch: sink seq[(bt.Block, Natural)]
  ): Future[?!void] {.async: (raises: [CancelledError]).} =
    ## Flush a batch of blocks to storage using batched putBlocks
    if batch.len == 0:
      return success()

    let batchStart = Moment.now()
    trace "Flushing block batch", count = batch.len

    # Convert to the format expected by putBlocks: (Block, Natural, ArchivistProof)
    # We don't have proofs yet (built after tree construction), so use nil
    var items: seq[(bt.Block, Natural, ArchivistProof)]
    for (blk, idx) in batch:
      items.add((blk, idx, nil))

    ?await self.repoStore.putBlocks(tmpCid, items)
    let batchDone = Moment.now()
    trace "Batch flush complete",
      duration = $(batchDone - batchStart), items = items.len

    archivist_upload_batch_flush_duration_seconds.observe(
      (batchDone - batchStart).milliseconds.float64 / 1000.0
    )
    success()

  let treeCid =
    ?await self.repoStore.withTmpOverlay(
      body = proc(
          tmpCid: Cid
      ): Future[?!Cid] {.closure, gcsafe, async: (raises: [CancelledError]).} =
        var
          index = 0
          cids: seq[Cid]
          inFlight: seq[Future[?!void]] ## Track in-flight batch flushes
          blockBatch: seq[(bt.Block, Natural)] ## (block, index) pairs for batching

        proc fireBoundedBatch(
            batch: seq[(bt.Block, Natural)]
        ): Future[?!void] {.async: (raises: [CancelledError]).} =
          # wait if at capacity before launching new batch
          if inFlight.len >= MaxInFlightBatches:
            # Remove first future and await it (cleanup before await to avoid leak)
            let fut = ?catchAsync(await one(inFlight))
            inFlight.keepItIf(FutureBase(it) != FutureBase(fut))
            ?catchAsync(?await fut)

          # Launch batch flush without awaiting (adds to window)
          var batch = batch
          inFlight.add(flushBatch(tmpCid, move batch))
          archivist_upload_batches_total.inc()
          archivist_upload_active_batches.set(inFlight.len.int64)

          success()

        defer:
          if inFlight.len > 0:
            warn "Early exit, cancelling outstanding upload batches",
              batches = inFlight.len
            await allFutures(inFlight.mapIt(it.cancelAndWait()))

        while true:
          let chunk = ?await chunker.getBytes()
          archivist_upload_bytes_total.inc(chunk.len.int64)
          if chunk.len == 0:
            trace "Chunker finished reading stream", read = NBytes(chunker.offset)
            break

          let
            mhash = ?MultiHash.digest($hcodec, chunk).mapFailure
            cid = ?Cid.init(CIDv1, dataCodec, mhash).mapFailure
            blk = ?bt.Block.new(cid, chunk, verify = false)

          archivist_upload_blocks_total.inc()
          cids.add(cid)
          blockBatch.add((blk, index.Natural))
          index.inc

          # Flush batch when full
          if blockBatch.len >= storeBatchSize:
            archivist_upload_active_batches.set(inFlight.len.int64)
            ?await fireBoundedBatch(blockBatch)
            archivist_upload_active_batches.set(inFlight.len.int64)
            blockBatch.setLen(0)

        # Flush batch on last iteration
        if blockBatch.len > 0:
          ?await fireBoundedBatch(blockBatch)
          blockBatch.setLen(0)

        await allFutures(inFlight)
        # return the first failed fut
        discard inFlight.mapIt(?catch(it.read))
        inFlight.setLen(0)

        let
          treeStart = Moment.now()
          tree = ?ArchivistTree.init(cids)
          treeCid = ?tree.rootCid(CIDv1, dataCodec)
          treeDone = Moment.now()
        archivist_upload_tree_build_duration_seconds.observe(
          (treeDone - treeStart).milliseconds.float64 / 1000.0
        )

        # TODO: Once we have progressive tree building we can get rid of the
        # separate proofs putting and just put leafs directly in the same
        # putBlock call as we build the tree
        var proofItems: seq[(Natural, Cid, ArchivistProof)]
        for index, cid in cids:
          proofItems.add((index.Natural, cid, ?tree.getProof(index)))
          if proofItems.len >= storeBatchSize:
            ?await self.repoStore.putCidsAndProofs(tmpCid, proofItems)
            proofItems.setLen(0)

        if proofItems.len > 0:
          ?await self.repoStore.putCidsAndProofs(tmpCid, proofItems)
          proofItems.setLen(0)

        success treeCid
    )

  let manifest = Manifest.new(
    treeCid = treeCid,
    blockSize = blockSize,
    datasetSize = NBytes(chunker.offset),
    version = CIDv1,
    hcodec = hcodec,
    codec = dataCodec,
    filename = filename,
    mimetype = mimetype,
  )

  # store the manifest
  let manifestBlk = ?await self.repoStore.storeManifest(manifest)

  # track manifest CID in overlay for cleanup
  ?await self.repoStore.putOverlay(treeCid, manifestCid = manifestBlk.cid.some)

  info "Stored data",
    manifestCid = manifestBlk.cid,
    treeCid = treeCid,
    blocks = manifest.blocksCount,
    datasetSize = manifest.datasetSize,
    filename = manifest.filename,
    mimetype = manifest.mimetype

  return manifestBlk.cid.success

proc iterateManifests*(
    self: ArchivistNodeRef, onManifest: OnManifest
) {.async: (raises: [CancelledError]).} =
  without cidsIter =? await self.networkStore.listBlocks(BlockType.Manifest):
    warn "Failed to listBlocks"
    return

  for c in cidsIter:
    if cid =? await c:
      without blk =? await self.networkStore.getBlock(cid):
        warn "Failed to get manifest block by cid", cid
        return

      without manifest =? Manifest.decode(blk):
        warn "Failed to decode manifest", cid
        return

      onManifest(cid, manifest)

proc ensureProtectedManifest(
    self: ArchivistNodeRef, manifest: Manifest, ecK: uint, ecM: uint
): Future[?!Manifest] {.async: (raises: [CancelledError]).} =
  # If the provided dataset is already erasure-coded,
  # then we require that the ecK and ecM parameters are an exact match.
  if manifest.protected:
    if manifest.ecK != ecK.int or manifest.ecM != ecM.int:
      return failure(
        "Attempt to proceed with protected manifest with parameters " & $(manifest.ecK) &
          "/" & $(manifest.ecM) & " but required: " & $ecK & "/" & $ecM
      )

    trace "Provided manifest is already protected"
    return success manifest

  # Erasure code the dataset according to provided parameters
  let
    erasure = Erasure.new(
      self.networkStore.localStore, self.repoStore, leoEncoderProvider,
      leoDecoderProvider, self.taskpool,
    )
    encodedManifest = ?await erasure.encode(manifest, ecK, ecM)
    manifestBlk = ?await self.repoStore.storeManifest(encodedManifest)

  success encodedManifest

proc ensureVerifiableManifest(
    self: ArchivistNodeRef, manifest: Manifest, ecK: uint, ecM: uint
): Future[?!Manifest] {.async: (raises: [CancelledError]).} =
  let protected = ?await self.ensureProtectedManifest(manifest, ecK, ecM)
  # If the provided dataset is already verifiable, use it
  if protected.verifiable:
    trace "Provided manifest is already verifiable"
    return success protected

  # Create verifiable manifest from protected manifest
  let builder =
    ?Poseidon2Builder.new(self.networkStore.localStore, self.repoStore, protected)
  return await builder.buildManifest()

proc setupRequest(
    self: ArchivistNodeRef,
    cid: Cid,
    duration: StorageDuration,
    proofProbability: UInt256,
    nodes: uint,
    tolerance: uint,
    pricePerBytePerSecond: TokensPerSecond,
    collateralPerByte: Tokens,
    expiry: StorageDuration,
): Future[?!StorageRequest] {.async: (raises: [CancelledError]).} =
  ## Setup slots for a given dataset
  ##

  let
    ecK = nodes - tolerance
    ecM = tolerance

  logScope:
    cid = cid
    duration = duration
    nodes = nodes
    tolerance = tolerance
    pricePerBytePerSecond = pricePerBytePerSecond
    proofProbability = proofProbability
    collateralPerByte = collateralPerByte
    expiry = expiry
    ecK = ecK
    ecM = ecM

  trace "Setting up slots"

  let
    manifest = ?await self.fetchManifest(cid)
    verifiable = ?await self.ensureVerifiableManifest(manifest, ecK, ecM)
    manifestBlk = ?await self.repoStore.storeManifest(verifiable)

    verifyRoot = (?verifiable.verifyRoot.fromVerifyCid).toBytes
    slotBytes = (verifiable.blockSize.int * verifiable.numSlotBlocks).NBytes

  let request = StorageRequest(
    ask: StorageAsk(
      slots: verifiable.numSlots.uint64,
      slotSize: slotBytes.uint64,
      duration: duration,
      proofProbability: proofProbability,
      pricePerBytePerSecond: pricePerBytePerSecond,
      collateralPerByte: collateralPerByte,
      maxSlotLoss: tolerance,
    ),
    content: StorageContent(cid: manifestBlk.cid, merkleRoot: verifyRoot),
    expiry: expiry,
  )

  trace "Request created", request = $request
  success request

proc requestStorage*(
    self: ArchivistNodeRef,
    cid: Cid,
    duration: StorageDuration,
    proofProbability: UInt256,
    nodes: uint,
    tolerance: uint,
    pricePerBytePerSecond: TokensPerSecond,
    collateralPerByte: Tokens,
    expiry: StorageDuration,
): Future[?!PurchaseId] {.async: (raises: [CancelledError]).} =
  ## Initiate a request for storage sequence, this might
  ## be a multistep procedure.
  ##

  logScope:
    cid = cid
    duration = duration
    nodes = nodes
    tolerance = tolerance
    pricePerBytePerSecond = pricePerBytePerSecond
    proofProbability = proofProbability
    collateralPerByte = collateralPerByte
    expiry = expiry

  trace "Received a request for storage!"

  without purchasing =? self.marketplace .? purchasing:
    trace "Purchasing not available"
    return failure "Purchasing not available"

  without request =? (
    await self.setupRequest(
      cid, duration, proofProbability, nodes, tolerance, pricePerBytePerSecond,
      collateralPerByte, expiry,
    )
  ), err:
    trace "Unable to setup request"
    return failure err

  let purchase = ?await purchasing.purchase(request)

  # Clean up verifiable and slot overlays when purchase completes (success or failure).
  # The original dataset overlay is not touched - it has its own TTL.
  let
    self = self
    verifiableCid = request.content.cid

  proc cleanupPurchaseOverlays() {.async: (raises: []).} =
    try:
      await purchase.future
    except CatchableError as exc:
      trace "Purchase future failed, cleaning up overlays", error = exc.msg

    try:
      without manifest =? await self.fetchManifest(verifiableCid), err:
        warn "Unable to fetch manifest for purchase cleanup",
          cid = verifiableCid, error = err.msg
        return

      for slotRoot in manifest.slotRoots:
        if err =? (await self.repoStore.dropOverlay(slotRoot)).errorOption:
          warn "Error dropping slot overlay", slotRoot, error = err.msg

      if err =? (await self.repoStore.dropOverlay(manifest.treeCid)).errorOption:
        warn "Error dropping verifiable overlay",
          treeCid = manifest.treeCid, error = err.msg
    except CancelledError:
      trace "Purchase overlay cleanup cancelled"

  self.trackedFutures.track(cleanupPurchaseOverlays())

  success purchase.id

proc validateVerifiableManifest(manifest: Manifest, slotSize: uint64): ?!void =
  if not manifest.verifiable:
    return failure("Received manifest type is not verifiable")
  if manifest.slotSize.uint64 != slotSize:
    return failure("Received manifest slotSize does not match storage request slotSize")
  return success()

proc storeSlot*(
    self: ArchivistNodeRef,
    cid: Cid,
    slotIndex: uint64,
    slotSize: uint64,
    expiry: SecondsSince1970,
    repair: bool,
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## store data in local storage
  ##
  logScope:
    cid = $cid
    slotIdx = slotIndex
    slotSize = slotSize

  trace "Received a request to store a slot"
  without manifest =? (await self.fetchManifest(cid)), err:
    error "Unable to fetch manifest for cid", cid, err = err.msg
    return failure(err)

  if err =? validateVerifiableManifest(manifest, slotSize).errorOption:
    error "Validation of verifiable manifest failed", err = err.msg
    return failure(err)

  # track manifest CID in overlay for cleanup
  ?await self.repoStore.putOverlay(manifest.treeCid, manifestCid = cid.some)

  if err =? (await self.updateExpiry(manifest, expiry)).errorOption:
    error "Unable to update manifest expiry", cid, err = err.msg
    return failure(err)

  without builder =?
    Poseidon2Builder.new(
      self.networkStore, self.repoStore, manifest, manifest.verifiableStrategy
    ), err:
    error "Unable to create slots builder", err = err.msg
    return failure(err)

  if slotIndex > manifest.slotRoots.high.uint64:
    error "Slot index not in manifest"
    return failure(newException(ArchivistError, "Slot index not in manifest"))

  if slotIndex > int.high.uint64:
    error "Cannot cast slot index to int", slotIndex = slotIndex
    return failure(newException(ArchivistError, "Cannot cast slot index to int"))

  without blksIter =? manifest.getSlotBlockIterator(slotIndex.int), err:
    error "Unable to get indices from strategy", err = err.msg
    return failure(err)

  if repair:
    trace "Start repairing slot", slotIdx
    let erasure = Erasure.new(
      self.networkStore, self.repoStore, leoEncoderProvider, leoDecoderProvider,
      self.taskpool,
    )
    if err =? (await erasure.repair(manifest)).errorOption:
      error "Unable to erasure decode repairing manifest",
        cid = manifest.treeCid, exc = err.msg
      return failure(err)

    while not blksIter.finished:
      without blk =? await self.networkStore.getBlock(manifest.treeCid, blksIter.next()),
        err:
        error "Unable to get slot block after repair"
        return failure(err)
  else:
    if err =? (await self.fetchBatched(manifest.treeCid, blksIter)).errorOption:
      error "Unable to fetch blocks", err = err.msg
      return failure(err)

  without slotRoot =? (await builder.buildSlot(slotIndex.int)), err:
    error "Unable to build slot", err = err.msg
    return failure(err)

  if cid =? slotRoot.toSlotCid() and cid != manifest.slotRoots[slotIndex]:
    error "Slot root mismatch",
      manifest = manifest.slotRoots[slotIndex.int], recovered = slotRoot.toSlotCid()
    return failure(newException(ArchivistError, "Slot root mismatch"))

  trace "Slot successfully retrieved and reconstructed"

  return success()

proc proveSlot*(
    self: ArchivistNodeRef, cid: Cid, slotIdx: uint64, challenge: ProofChallenge
): Future[?!Groth16Proof] {.async: (raises: [CancelledError]).} =
  ## Generates a proof for a given slot and challenge
  ##

  logScope:
    cid = $cid
    slot = slotIdx
    challenge = challenge

  trace "Received proof challenge"

  if prover =? self.prover:
    trace "Prover enabled"

    let
      manifest = ?await self.fetchManifest(cid)
      builder =
        ?Poseidon2Builder.new(
          self.networkStore, self.repoStore, manifest, manifest.verifiableStrategy
        )
      sampler = ?Poseidon2Sampler.new(slotIdx, self.networkStore, builder)

    when defined(verify_circuit):
      let (proof, checked) =
        ?await prover.prove(sampler, manifest, challenge, verify = true)

      if checked.isSome and not checked.get:
        error "Proof verification failed"
        return failure("Proof verification failed")

      trace "Proof verified successfully"
    else:
      let (proof, _) = ?await prover.prove(sampler, manifest, challenge, verify = false)

    trace "Proof generated successfully", proof

    success proof
  else:
    warn "Prover not enabled"
    failure "Prover not enabled"

proc deleteSlot*(
    self: ArchivistNodeRef, cid: Cid, slotIdx: uint64
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Handle slot failure - mark overlay as failed so maintenance will drop it
  ##
  logScope:
    cid = $cid
    slot = slotIdx

  trace "Marking slot as failed"

  let manifest = ?await self.fetchManifest(cid)
  if not manifest.verifiable:
    warn "Attempting to fail a slot with a non-verifiable manifest", cid, slotIdx

  let slotCid = manifest.slotRoots[slotIdx]

  # Delete slot overlay
  if err =? (await self.repoStore.dropOverlay(slotCid)).errorOption:
    warn "Error marking slot overlay failed", err = err.msg

  # Delete mainfest overlay
  if err =? (await self.repoStore.dropOverlay(manifest.treeCid)).errorOption:
    warn "Error marking tree overlay failed", err = err.msg

  trace "Slot marked as failed"

  return success()

proc start*(self: ArchivistNodeRef) {.async.} =
  if not self.engine.isNil:
    await self.engine.start()

  if not self.discovery.isNil:
    await self.discovery.start()

  if marketplace =? self.marketplace:
    if error =? (await marketplace.start()).errorOption:
      error "Unable to start marketplace", error = error.msg

  self.networkId = self.switch.peerInfo.peerId
  notice "Started node", id = self.networkId, addrs = self.switch.peerInfo.addrs

proc stop*(self: ArchivistNodeRef) {.async.} =
  trace "Stopping node"

  await self.trackedFutures.cancelTracked()

  if not self.engine.isNil:
    await self.engine.stop()

  if not self.discovery.isNil:
    await self.discovery.stop()

  if marketplace =? self.marketplace:
    await marketplace.stop()

  if not self.networkStore.isNil:
    await self.networkStore.close

proc new*(
    T: type ArchivistNodeRef,
    switch: Switch,
    networkStore: NetworkStore,
    repoStore: RepoStore,
    engine: BlockExcEngine,
    discovery: Discovery,
    taskpool: Taskpool,
    prover = Prover.none,
    marketplace = MarketplaceNode.none,
): ArchivistNodeRef =
  ## Create new instance of a node, call `start` to run it
  ##

  ArchivistNodeRef(
    switch: switch,
    networkStore: networkStore,
    repoStore: repoStore,
    engine: engine,
    prover: prover,
    discovery: discovery,
    taskPool: taskpool,
    marketplace: marketplace,
    trackedFutures: TrackedFutures(),
  )
