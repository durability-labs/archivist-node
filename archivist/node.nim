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
import std/strformat
import std/sugar
import std/tables
import times

import pkg/taskpools
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
import ./utils/fileutils
import ./utils/manifest as manifestutils

export logutils

logScope:
  topics = "archivist node"

const DefaultFetchBatch = 10

type
  ArchivistNode* = object
    switch: Switch
    networkId: PeerId
    networkStore: NetworkStore
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

proc storeManifest*(
    self: ArchivistNodeRef, manifest: Manifest
): Future[?!bt.Block] {.async: (raises: [CancelledError]).} =
  ## Store a manifest to the network store
  ##
  await manifestutils.storeManifest(self.networkStore, manifest)

proc fetchManifest*(
    self: ArchivistNodeRef, cid: Cid
): Future[?!Manifest] {.async: (raises: [CancelledError]).} =
  ## Fetch and decode a manifest block
  ##
  await manifestutils.fetchManifest(self.networkStore, cid)

proc fetchManifest*(
    self: ArchivistNodeRef, cid: Cid, expiry: SecondsSince1970
): Future[?!Manifest] {.async: (raises: [CancelledError]).} =
  ## Fetch manifest and update its expiry
  ##
  let manifest = ?await self.fetchManifest(cid)
  ?await self.networkStore.ensureExpiry(cid, expiry)
  success(manifest)

proc findPeer*(self: ArchivistNodeRef, peerId: PeerId): Future[?PeerRecord] {.async.} =
  ## Find peer using the discovery service from the given ArchivistNode
  ##
  return await self.discovery.findPeer(peerId)

proc connect*(
    self: ArchivistNodeRef, peerId: PeerId, addrs: seq[MultiAddress]
): Future[void] =
  self.switch.connect(peerId, addrs)

proc updateExpiry*(
    self: ArchivistNodeRef, manifestCid: Cid, expiry: SecondsSince1970
): Future[?!void] {.async: (raises: [CancelledError]).} =
  without manifest =? await self.fetchManifest(manifestCid, expiry), error:
    trace "Unable to fetch manifest for cid", manifestCid
    return failure(error)

  try:
    let ensuringFutures = Iter[int].new(0 ..< manifest.blocksCount).mapIt(
        self.networkStore.ensureExpiry(manifest.treeCid, it, expiry)
      )

    let res = await allFinishedFailed[?!void](ensuringFutures)
    if res.failure.len > 0:
      trace "Some blocks failed to update expiry", len = res.failure.len
      return failure("Some blocks failed to update expiry (" & $res.failure.len & " )")
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return failure(exc.msg)

  return success()

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

  # TODO: doesn't work if callee is annotated with async
  # let
  #   iter = iter.map(
  #     (i: int) => self.networkStore.getBlock(BlockAddress.init(cid, i))
  #   )

  while not iter.finished:
    let blockFutures = collect:
      for i in 0 ..< batchSize:
        if not iter.finished:
          let address = BlockAddress.init(cid, iter.next())
          if not (await address in self.networkStore) or fetchLocal:
            self.networkStore.getBlock(address)

    if blockFutures.len == 0:
      continue

    without blockResults =? await allFinishedValues[?!bt.Block](blockFutures), err:
      trace "Some blocks failed to fetch", err = err.msg
      return failure(err)

    let blocks = blockResults.filterIt(it.isSuccess()).mapIt(it.value)

    let numOfFailedBlocks = blockResults.len - blocks.len
    if numOfFailedBlocks > 0:
      return
        failure("Some blocks failed (Result) to fetch (" & $numOfFailedBlocks & ")")

    if not onBatch.isNil and batchErr =? (await onBatch(blocks)).errorOption:
      return failure(batchErr)

    if not iter.finished:
      await sleepAsync(1.millis)

  success()

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
  self.trackedFutures.track(self.fetchDatasetAsync(manifest, fetchLocal = false))

proc streamSingleBlock(
    self: ArchivistNodeRef, cid: Cid
): Future[?!LPStream] {.async: (raises: [CancelledError]).} =
  ## Streams the contents of a single block.
  ##
  trace "Streaming single block", cid = cid

  let stream = BufferStream.new()

  without blk =? (await self.networkStore.getBlock(BlockAddress.init(cid))), err:
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
    # Retrieve, decode and save to the local store all EС groups
    proc erasureJob(): Future[void] {.async: (raises: []).} =
      try:
        # Spawn an erasure decoding job
        let erasure = Erasure.new(
          self.networkStore, leoEncoderProvider, leoDecoderProvider, self.taskpool
        )
        without _ =? (await erasure.decode(manifest)), error:
          error "Unable to erasure decode manifest", manifestCid, exc = error.msg
      except CatchableError as exc:
        trace "Error erasure decoding manifest", manifestCid, exc = exc.msg

    jobs.add(erasureJob())

  jobs.add(self.fetchDatasetAsync(manifest, fetchLocal = false))

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

  if not (await cid in store):
    # As per the contract for delete*, an absent dataset is not an error.
    return success()

  without manifestBlock =? await store.getBlock(cid), err:
    return failure(err)

  without manifest =? Manifest.decode(manifestBlock), err:
    return failure(err)

  let runtimeQuota = initDuration(milliseconds = 100)
  var lastIdle = getTime()
  for i in 0 ..< manifest.blocksCount:
    if (getTime() - lastIdle) >= runtimeQuota:
      await idleAsync()
      lastIdle = getTime()

    if err =? (await store.delBlock(manifest.treeCid, i)).errorOption:
      # The contract for delBlock is fuzzy, but we assume that if the block is
      # simply missing we won't get an error. This is a best effort operation and
      # can simply be retried.
      error "Failed to delete block within dataset", index = i, err = err.msg
      return failure(err)

  if err =? (await store.delBlock(cid)).errorOption:
    error "Error deleting manifest block", err = err.msg

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
    path: ?string = string.none,
    mimetype: ?string = string.none,
    blockSize = DefaultBlockSize,
): Future[?!Cid] {.async: (raises: [CancelledError]).} =
  ## Save stream contents as dataset with given blockSize
  ## to nodes's BlockStore, and return Cid of its manifest
  ##
  info "Storing data"

  let
    hcodec = Sha256HashCodec
    dataCodec = BlockCodec
    chunker = LPStreamChunker.new(stream, chunkSize = blockSize)

  var cids: seq[Cid]

  try:
    while (let chunk = await chunker.getBytes(); chunk.len > 0):
      without mhash =? MultiHash.digest($hcodec, chunk).mapFailure, err:
        return failure(err)

      without cid =? Cid.init(CIDv1, dataCodec, mhash).mapFailure, err:
        return failure(err)

      without blk =? bt.Block.new(cid, chunk, verify = false):
        return failure("Unable to init block from chunk!")

      cids.add(cid)

      if err =? (await self.networkStore.putBlock(blk)).errorOption:
        error "Unable to store block", cid = blk.cid, err = err.msg
        return failure(&"Unable to store block {blk.cid}")
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    return failure(exc.msg)
  finally:
    await stream.close()

  without tree =? ArchivistTree.init(cids), err:
    return failure(err)

  without treeCid =? tree.rootCid(CIDv1, dataCodec), err:
    return failure(err)

  for index, cid in cids:
    without proof =? tree.getProof(index), err:
      return failure(err)
    if err =?
        (await self.networkStore.putCidAndProof(treeCid, index, cid, proof)).errorOption:
      # TODO add log here
      return failure(err)

  let manifest = Manifest.new(
    treeCid = treeCid,
    blockSize = blockSize,
    datasetSize = NBytes(chunker.offset),
    version = CIDv1,
    hcodec = hcodec,
    codec = dataCodec,
    path = path,
    mimetype = mimetype,
  )

  without manifestBlk =? await self.storeManifest(manifest), err:
    error "Unable to store manifest"
    return failure(err)

  info "Stored data",
    manifestCid = manifestBlk.cid,
    treeCid = treeCid,
    blocks = manifest.blocksCount,
    datasetSize = manifest.datasetSize,
    path = manifest.path,
    mimetype = manifest.mimetype

  return manifestBlk.cid.success

proc storeDirectory*(
    self: ArchivistNodeRef, name: string, entryCids: seq[Cid]
): Future[?!Cid] {.async: (raises: [CancelledError]).} =
  ## Create and store a directory manifest from existing file manifests.
  ## All entry CIDs must exist in the store and be valid manifests.
  ## Paths are extracted from each manifest's `path` field.
  ## If a manifest has no path, its CID string is used as the filename.
  ## Returns the CID of the directory manifest.
  ##

  if entryCids.len == 0:
    return failure("Directory must have at least one entry")

  # Fetch all manifests, extract paths, and build entries table
  var entries: OrderedTable[string, Cid]
  var totalSize: NBytes = 0.NBytes
  var firstManifest: Manifest

  for i, cid in entryCids:
    without manifest =? await self.fetchManifest(cid), err:
      return failure("Entry CID '" & $cid & "' not found or invalid: " & err.msg)

    if i == 0:
      firstManifest = manifest

    # Extract path from manifest, or use CID string if no path
    let path =
      if manifest.path.isSome and manifest.path.get.len > 0:
        manifest.path.get
      else:
        $cid

    # Validate the path
    if not isValidVirtualPath(path):
      return failure("Invalid path in manifest: " & path)

    # Check for duplicate paths
    if path in entries:
      return failure("Duplicate path: " & path)

    entries[path] = cid

    # Accumulate the dataset size (actual stored size)
    totalSize = totalSize + manifest.datasetSize

  # Create the directory manifest
  let dirManifest = Manifest.new(
    treeCid = firstManifest.treeCid, # Placeholder - directory doesn't have its own tree
    blockSize = firstManifest.blockSize, # Use first entry's block size
    datasetSize = totalSize,
    name = name,
    entries = entries,
  )

  without manifestBlk =? await self.storeManifest(dirManifest), err:
    error "Unable to store directory manifest"
    return failure(err)

  info "Stored directory",
    manifestCid = manifestBlk.cid,
    name = name,
    fileCount = entries.len,
    totalSize = totalSize

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

proc setupRequest(
    self: ArchivistNodeRef,
    cid: Cid,
    duration: uint64,
    proofProbability: UInt256,
    nodes: uint,
    tolerance: uint,
    pricePerBytePerSecond: UInt256,
    collateralPerByte: UInt256,
    expiry: uint64,
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

    # Erasure code the dataset according to provided parameters
    erasure = Erasure.new(
      self.networkStore.localStore, leoEncoderProvider, leoDecoderProvider,
      self.taskpool,
    )

    encoded = ?await erasure.encode(manifest, ecK, ecM)
    # Slot construction uses opposite strategy from erasure coding
    slotStrategy = encoded.protectedStrategy.opposite
    builder = ?Poseidon2Builder.new(self.networkStore.localStore, encoded, slotStrategy)
    verifiable = ?await builder.buildManifest()
    manifestBlk = ?await self.storeManifest(verifiable)

    verifyRoot =
      if builder.verifyRoot.isNone:
        return failure("No slots root")
      else:
        builder.verifyRoot.get.toBytes

    request = StorageRequest(
      ask: StorageAsk(
        slots: verifiable.numSlots.uint64,
        slotSize: builder.slotBytes.uint64,
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
    duration: uint64,
    proofProbability: UInt256,
    nodes: uint,
    tolerance: uint,
    pricePerBytePerSecond: UInt256,
    collateralPerByte: UInt256,
    expiry: uint64,
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
  success purchase.id

proc storeSlot*(
    self: ArchivistNodeRef,
    cid: Cid,
    slotIdx: uint64,
    expiry: SecondsSince1970,
    repair: bool,
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## store data in local storage
  ##
  logScope:
    cid = $cid
    slotIdx = slotIdx

  trace "Received a request to store a slot"

  without manifest =? (await self.fetchManifest(cid, expiry)), err:
    error "Unable to fetch manifest for cid", cid, err = err.msg
    return failure(err)

  without builder =?
    Poseidon2Builder.new(self.networkStore, manifest, manifest.verifiableStrategy), err:
    error "Unable to create slots builder", err = err.msg
    return failure(err)

  if slotIdx > manifest.slotRoots.high.uint64:
    error "Slot index not in manifest", slotIdx
    return failure(newException(ArchivistError, "Slot index not in manifest"))

  proc updateExpiry(
      blocks: seq[bt.Block]
  ): Future[?!void] {.async: (raises: [CancelledError]).} =
    trace "Updating expiry for blocks", blocks = blocks.len

    let ensureExpiryFutures =
      blocks.mapIt(self.networkStore.ensureExpiry(it.cid, expiry))

    let res = await allFinishedFailed[?!void](ensureExpiryFutures)
    if res.failure.len > 0:
      error "Some blocks failed to update expiry", len = res.failure.len
      return failure("Some blocks failed to update expiry (" & $res.failure.len & " )")

    return success()

  if slotIdx > int.high.uint64:
    error "Cannot cast slot index to int", slotIndex = slotIdx
    return failure(newException(ArchivistError, "Cannot cast slot index to int"))

  without blksIter =? manifest.getSlotBlockIterator(slotIdx.int), err:
    error "Unable to get indices from strategy", err = err.msg
    return failure(err)

  if repair:
    trace "start repairing slot", slotIdx
    try:
      let erasure = Erasure.new(
        self.networkStore, leoEncoderProvider, leoDecoderProvider, self.taskpool
      )
      if err =? (await erasure.repair(manifest)).errorOption:
        error "Unable to erasure decode repairing manifest",
          cid = manifest.treeCid, exc = err.msg
        return failure(err)

      # Iterate the slot blocks. Provide them to the updateExpiry callback.
      while not blksIter.finished:
        without blk =?
          await self.networkStore.getBlock(manifest.treeCid, blksIter.next()), err:
          error "Unable to get slot block after repair"
          return failure(err)
        if err =? (await updateExpiry(@[blk])).errorOption:
          error "Unable to update expiry for slot block after repair"
          return failure(err)
    except CatchableError as exc:
      error "Error erasure decoding repairing manifest",
        cid = manifest.treeCid, exc = exc.msg
      return failure(exc.msg)
  else:
    if err =? (
      await self.fetchBatched(manifest.treeCid, blksIter, onBatch = updateExpiry)
    ).errorOption:
      error "Unable to fetch blocks", err = err.msg
      return failure(err)

  without slotRoot =? (await builder.buildSlot(slotIdx.int)), err:
    error "Unable to build slot", err = err.msg
    return failure(err)

  if cid =? slotRoot.toSlotCid() and cid != manifest.slotRoots[slotIdx]:
    error "Slot root mismatch",
      manifest = manifest.slotRoots[slotIdx.int], recovered = slotRoot.toSlotCid()
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
        ?Poseidon2Builder.new(self.networkStore, manifest, manifest.verifiableStrategy)
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
    engine: engine,
    prover: prover,
    discovery: discovery,
    taskPool: taskpool,
    marketplace: marketplace,
    trackedFutures: TrackedFutures(),
  )
