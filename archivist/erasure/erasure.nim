## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/[sugar, atomics, sequtils]

import pkg/chronos
import pkg/chronos/threadsync
import pkg/chronicles
import pkg/libp2p/[multicodec, cid, multihash]
import pkg/libp2p/protobuf/minprotobuf
import pkg/taskpools

import ../logutils
import ../manifest
import ../merkletree
import ../stores
import ../blocktype as bt
import ../utils
import ../utils/asynciter
import ../indexingstrategy
import ../errors

import pkg/stew/byteutils

import ./backend

export backend

logScope:
  topics = "archivist erasure"

type
  ## Encode a manifest into one that is erasure protected.
  ##
  ## The new manifest has K `blocks` that are encoded into
  ## additional M `parity` blocks. The resulting dataset
  ## is padded with empty blocks if it doesn't have a square
  ## shape.
  ##
  ## NOTE: The padding blocks could be excluded
  ## from transmission, but they aren't for now.
  ##
  ## The resulting dataset is logically divided into rows
  ## where a row is made up of B blocks. There are then,
  ## K + M = N rows in total, each of length B blocks. Rows
  ## are assumed to be of the same number of (B) blocks.
  ##
  ## The encoding is systematic and the rows can be
  ## read sequentially by any node without decoding.
  ##
  ## Decoding is possible with any K rows or partial K
  ## columns (with up to M blocks missing per column),
  ## or any combination there of.
  ##
  EncoderProvider* =
    proc(size, blocks, parity: int): EncoderBackend {.raises: [Defect], noSideEffect.}

  DecoderProvider* =
    proc(size, blocks, parity: int): DecoderBackend {.raises: [Defect], noSideEffect.}

  Erasure* = ref object
    taskPool: Taskpool
    encoderProvider*: EncoderProvider
    decoderProvider*: DecoderProvider
    networkStore*: BlockStore
    repoStore*: RepoStore

  EncodingParams = object
    blockSize: NBytes
    ecK: Natural
    ecM: Natural
    rounded: Natural
    steps: Natural
    blocksCount: Natural
    encodedBlocksCount: Natural
    strategy: StrategyType
    emptyCid: Cid

  ErasureError* = object of ArchivistError
  InsufficientBlocksError* = object of ErasureError
    # Minimum size, in bytes, that the dataset must have had
    # for the encoding request to have succeeded with the parameters
    # provided.
    minSize*: NBytes

  EncodeTask = object
    success: Atomic[bool]
    erasure: ptr Erasure
    blocks: ref seq[seq[byte]]
    parity: ref seq[seq[byte]]
    blockSize: int
    signal: ThreadSignalPtr

  DecodeTask = object
    success: Atomic[bool]
    erasure: ptr Erasure
    blocks: ref seq[seq[byte]]
    parity: ref seq[seq[byte]]
    recovered: ref seq[seq[byte]]
    blockSize: int
    signal: ThreadSignalPtr

func indexToPos(steps, idx, step: int): int {.inline.} =
  ## Convert an index to a position in the encoded
  ##  dataset
  ## `idx`  - the index to convert
  ## `step` - the current step
  ## `pos`  - the position in the encoded dataset
  ##

  (idx - step) div steps

proc getPendingBlocks(
    self: Erasure, treeCid: Cid, indices: seq[int]
): AsyncIter[(?!bt.Block, int)] =
  ## Get pending blocks iterator
  ##
  var
    pendingBlocks: seq[Future[(?!bt.Block, int)]] = @[]
    disposed = false

  proc attachIndex(
      fut: Future[?!bt.Block], i: int
  ): Future[(?!bt.Block, int)] {.async.} =
    ## avoids closure capture issues
    return (await fut, i)

  for blockIndex in indices:
    # request blocks from the store
    let fut = self.networkStore.getBlock(treeCid, blockIndex)
    pendingBlocks.add(attachIndex(fut, blockIndex))

  proc isFinished(): bool =
    disposed or pendingBlocks.len == 0

  proc dispose(): Future[void] {.async.} =
    disposed = true
    pendingBlocks.setLen(0)

  proc isDisposed(): bool =
    disposed

  proc genNext(): Future[(?!bt.Block, int)] {.async.} =
    let completedFut = await one(pendingBlocks)
    if (let i = pendingBlocks.find(completedFut); i >= 0):
      pendingBlocks.del(i)
      return await completedFut
    else:
      let (_, index) = await completedFut
      raise newException(
        CatchableError,
        "Future for block id not found, tree cid: " & $treeCid & ", index: " & $index,
      )

  AsyncIter[(?!bt.Block, int)].new(genNext, isFinished, dispose, isDisposed)

proc prepareEncodingData(
    self: Erasure,
    treeCid: Cid,
    params: EncodingParams,
    step: Natural,
    data: ref seq[seq[byte]],
    cids: ref seq[Cid],
    emptyCid: Cid,
    emptyBlock: seq[byte],
): Future[?!Natural] {.async: (raises: [CancelledError]).} =
  ## Prepare data for encoding
  ##

  logScope:
    treeCid = treeCid
    step = step
    blocksCount = params.blocksCount
    rounded = params.rounded
    strategy = params.strategy

  trace "Preparing encoding data"
  let
    strategy =
      ?catch(
        params.strategy.init(
          firstIndex = 0, lastIndex = params.rounded - 1, iterations = params.steps
        )
      )
    indices = toSeq(?catch(strategy.getIndices(step)))
    pendingBlocksIter =
      self.getPendingBlocks(treeCid, indices.filterIt(it < params.blocksCount))

  defer:
    if err =? catchAsync(await pendingBlocksIter.dispose()).errorOption:
      warn "Failed to dispose pending encoding block iterator", err = err.msg

  var resolved = 0
  while not pendingBlocksIter.finished:
    let
      (blkOrErr, idx) = ?catchAsync(await pendingBlocksIter.next())
      blk = ?blkOrErr

    let pos = indexToPos(params.steps, idx, step)
    data[pos] = if blk.isEmpty: emptyBlock else: blk.data
    cids[idx] = blk.cid

    resolved.inc()

  for idx in indices.filterIt(it >= params.blocksCount):
    let pos = indexToPos(params.steps, idx, step)
    trace "Padding with empty block", idx
    data[pos] = emptyBlock
    cids[idx] = emptyCid

  success(resolved.Natural)

proc prepareDecodingData(
    self: Erasure,
    treeCid: Cid,
    params: EncodingParams,
    step: Natural,
    data: ref seq[seq[byte]],
    parityData: ref seq[seq[byte]],
    cids: ref seq[Cid],
    emptyBlock: seq[byte],
): Future[?!(Natural, Natural)] {.async: (raises: [CancelledError]).} =
  ## Prepare data for decoding
  ## `treeCid`    - the tree cid to fetch blocks from
  ## `params`     - encoding parameters
  ## `step`       - the current step
  ## `data`       - the data to be prepared
  ## `parityData` - the parityData to be prepared
  ## `cids`       - cids of prepared data
  ## `emptyBlock` - the empty block to be used for padding
  ##

  let
    strategy =
      ?catch(
        params.strategy.init(
          firstIndex = 0,
          lastIndex = params.encodedBlocksCount - 1,
          iterations = params.steps,
        )
      )
    indices = toSeq(?catch(strategy.getIndices(step)))
    pendingBlocksIter = self.getPendingBlocks(treeCid, indices)

  defer:
    if err =? catchAsync(await pendingBlocksIter.dispose()).errorOption:
      warn "Failed to dispose pending decoding block iterator", err = err.msg

  var
    dataPieces = 0
    parityPieces = 0
    resolved = 0
  while not pendingBlocksIter.finished and resolved < params.ecK:
    # Continue to receive blocks until we have just enough for decoding
    # or no more blocks can arrive
    let (blkOrErr, idx) = ?catchAsync(await pendingBlocksIter.next())
    without blk =? blkOrErr, err:
      trace "Failed retrieving a block", idx, treeCid = treeCid, msg = err.msg
      continue

    let pos = indexToPos(params.steps, idx, step)

    logScope:
      cid = blk.cid
      idx = idx
      pos = pos
      step = step
      empty = blk.isEmpty

    cids[idx] = blk.cid
    if idx >= params.rounded:
      trace "Retrieved parity block"
      parityData[pos - params.ecK] = if blk.isEmpty: emptyBlock else: blk.data
      parityPieces.inc
    else:
      trace "Retrieved data block"
      data[pos] = if blk.isEmpty: emptyBlock else: blk.data
      dataPieces.inc

    resolved.inc

  return success (dataPieces.Natural, parityPieces.Natural)

proc init*(
    _: type EncodingParams,
    manifest: Manifest,
    ecK: Natural,
    ecM: Natural,
    strategy: StrategyType,
    emptyCid: Cid,
): ?!EncodingParams =
  if ecK > manifest.blocksCount:
    let exc = (ref InsufficientBlocksError)(
      msg:
        "Unable to encode manifest, not enough blocks, ecK = " & $ecK &
        ", blocksCount = " & $manifest.blocksCount,
      minSize: ecK.NBytes * manifest.blockSize,
    )
    return failure(exc)

  let
    rounded = roundUp(manifest.blocksCount, ecK)
    steps = divUp(rounded, ecK)

  success EncodingParams(
    blockSize: manifest.blockSize,
    ecK: ecK,
    ecM: ecM,
    rounded: rounded,
    steps: steps,
    blocksCount: manifest.blocksCount,
    encodedBlocksCount: rounded + (steps * ecM),
    strategy: strategy,
    emptyCid: emptyCid,
  )

proc initFromEncoded*(
    _: type EncodingParams, encoded: Manifest, emptyCid: Cid
): EncodingParams =
  ## Construct EncodingParams from an already-encoded manifest.
  ##
  EncodingParams(
    blockSize: encoded.blockSize,
    ecK: encoded.ecK,
    ecM: encoded.ecM,
    rounded: encoded.rounded,
    steps: encoded.steps,
    blocksCount: encoded.originalBlocksCount,
    encodedBlocksCount: encoded.blocksCount,
    strategy: encoded.protectedStrategy,
    emptyCid: emptyCid,
  )

proc leopardEncodeTask(tp: Taskpool, task: ptr EncodeTask) {.gcsafe.} =
  let encoder = task[].erasure.encoderProvider(
    task[].blockSize, task[].blocks[].len, task[].parity[].len
  )
  defer:
    encoder.release()
    discard task[].signal.fireSync()

  if (let res = encoder.encode(task[].blocks[], task[].parity[]); res.isErr):
    warn "Error from leopard encoder backend!", error = $res.error

    task[].success.store(false)
  else:
    task[].success.store(true)

proc asyncEncode*(
    self: Erasure,
    blockSize: int,
    blocks: ref seq[seq[byte]],
    parity: ref seq[seq[byte]],
): Future[?!void] {.async: (raises: [CancelledError]).} =
  without threadPtr =? ThreadSignalPtr.new():
    return failure("Unable to create thread signal")

  defer:
    threadPtr.close().expect("closing once works")

  ## Create an ecode task with block data
  var task = EncodeTask(
    erasure: addr self,
    blockSize: blockSize,
    blocks: blocks,
    parity: parity,
    signal: threadPtr,
  )

  doAssert self.taskPool.numThreads > 1,
    "Must have at least one separate thread or signal will never be fired"
  self.taskPool.spawn leopardEncodeTask(self.taskPool, addr task)
  let threadFut = threadPtr.wait()

  if joinErr =? catch(await threadFut.join()).errorOption:
    if err =? catch(await noCancel threadFut).errorOption:
      return failure(err)
    if joinErr of CancelledError:
      raise (ref CancelledError) joinErr
    else:
      return failure(joinErr)

  if not task.success.load():
    return failure("Leopard encoding task failed")

  success()

proc encodeData(
    self: Erasure, originalTreeCid: Cid, tmpTreeCid: Cid, params: EncodingParams
): Future[?!ref seq[Cid]] {.async: (raises: [CancelledError]).} =
  ## Encode blocks and return the cids of all blocks (data + parity).
  ## Tree construction, proof storage, and manifest creation are
  ## handled by the caller.
  ##
  logScope:
    originalTreeCid = originalTreeCid
    tmpTreeCid = tmpTreeCid
    steps = params.steps
    roundedBlocks = params.rounded
    blocksCount = params.blocksCount
    encodedBlocksCount = params.encodedBlocksCount
    ecK = params.ecK
    ecM = params.ecM

  trace "Starting erasure coding dataset"
  var
    cids = seq[Cid].new()
    emptyBlock = newSeq[byte](params.blockSize.int)

  cids[].setLen(params.encodedBlocksCount)
  for step in 0 ..< params.steps:
    # TODO: Don't allocate a new seq every time, allocate once and zero out
    var
      data = new seq[seq[byte]] # number of blocks to encode
      parity = new seq[seq[byte]]

    data[].setLen(params.ecK)
    parity[] = newSeqWith(params.ecM, newSeqWith(params.blockSize.int, 0'u8))

    let resolved =
      ?await self.prepareEncodingData(
        originalTreeCid, params, step, data, cids, params.emptyCid, emptyBlock
      )

    trace "Erasure coding data", data = data[].len
    ?await self.asyncEncode(params.blockSize.int, data, parity)
    var
      idx = params.rounded + step
      blocks: seq[(bt.Block, Natural, ArchivistProof)]

    for j in 0 ..< params.ecM:
      let blk = ?bt.Block.new(parity[j])

      trace "Adding parity block", cid = blk.cid, idx
      cids[idx] = blk.cid
      blocks.add((blk, idx.Natural, nil))
      idx.inc(params.steps)

    trace "Storing parity blocks", count = blocks.len
    ?await self.networkStore.putBlocks(tmpTreeCid, blocks)

  trace "Encoding complete", encodedBlocksCount = params.encodedBlocksCount
  success cids

proc encode*(
    self: Erasure,
    manifest: Manifest,
    blocks: Natural,
    parity: Natural,
    strategy = SteppedStrategy,
): Future[?!Manifest] {.async: (raises: [CancelledError]).} =
  ## Encode a manifest into one that is erasure protected.
  ##
  ## `manifest`   - the original manifest to be encoded
  ## `blocks`     - the number of blocks to be encoded - K
  ## `parity`     - the number of parity blocks to generate - M
  ##

  let
    emptyCid = ?emptyCid(manifest.version, manifest.hcodec, manifest.codec)
    sourceManifest =
      if manifest.protected:
        Manifest.new(manifest)
      else:
        manifest
    params =
      ?EncodingParams.init(sourceManifest, blocks.int, parity.int, strategy, emptyCid)

  proc treeAndProofs(
      cids: ref seq[Cid], targetCid: Cid
  ): Future[?!Cid] {.async: (raises: [CancelledError]).} =
    let
      tree = ?ArchivistTree.init(cids[])
      treeCid = ?tree.rootCid

    var proofItems: seq[(Natural, Cid, ArchivistProof)]
    for index, cid in cids[]:
      proofItems.add((index.Natural, cid, ?tree.getProof(index)))

    ?await self.networkStore.putCidsAndProofs(targetCid, proofItems)

    trace "Tree and proofs stored", treeCid, blocks = blocks, parity = parity
    success treeCid

  let treeCid =
    if manifest.protected:
      ?await self.repoStore.withOverlay(
        manifest.treeCid,
        body = proc(): Future[?!Cid] {.
            closure, gcsafe, async: (raises: [CancelledError])
        .} =
          let cids =
            ?await self.encodeData(sourceManifest.treeCid, manifest.treeCid, params)
          await treeAndProofs(cids, manifest.treeCid)
        ,
      )
    else:
      ?await self.repoStore.withTmpOverlay(
        body = proc(
            tmpCid: Cid
        ): Future[?!Cid] {.closure, gcsafe, async: (raises: [CancelledError]).} =
          let cids = ?await self.encodeData(sourceManifest.treeCid, tmpCid, params)

          await treeAndProofs(cids, tmpCid)
      )

  let protected = Manifest.new(
    manifest = sourceManifest,
    treeCid = treeCid,
    ecK = blocks.int,
    ecM = parity.int,
    strategy = strategy,
    datasetSize = (sourceManifest.blockSize.int * params.encodedBlocksCount).NBytes,
  )

  success(protected)

proc leopardDecodeTask(tp: Taskpool, task: ptr DecodeTask) {.gcsafe.} =
  # Task suitable for running in taskpools - look, no GC!
  let decoder = task[].erasure.decoderProvider(
    task[].blockSize, task[].blocks[].len, task[].parity[].len
  )
  defer:
    decoder.release()
    discard task[].signal.fireSync()

  if (
    let res = decoder.decode(task[].blocks[], task[].parity[], task[].recovered[])
    res.isErr
  ):
    warn "Error from leopard decoder backend!", error = $res.error
    task[].success.store(false)
  else:
    task[].success.store(true)

proc asyncDecode*(
    self: Erasure,
    blockSize: int,
    blocks, parity: ref seq[seq[byte]],
    recovered: ref seq[seq[byte]],
): Future[?!void] {.async: (raises: [CancelledError]).} =
  without threadPtr =? ThreadSignalPtr.new():
    return failure("Unable to create thread signal")

  defer:
    threadPtr.close().expect("closing once works")

  ## Create an decode task with block data
  var task = DecodeTask(
    erasure: addr self,
    blockSize: blockSize,
    blocks: blocks,
    parity: parity,
    recovered: recovered,
    signal: threadPtr,
  )

  doAssert self.taskPool.numThreads > 1,
    "Must have at least one separate thread or signal will never be fired"
  self.taskPool.spawn leopardDecodeTask(self.taskPool, addr task)
  let threadFut = threadPtr.wait()

  if joinErr =? catch(await threadFut.join()).errorOption:
    if err =? catch(await noCancel threadFut).errorOption:
      return failure(err)
    if joinErr of CancelledError:
      raise (ref CancelledError) joinErr
    else:
      return failure(joinErr)

  if not task.success.load():
    return failure("Leopard decoding task failed")

  success()

proc decodeInternal(
    self: Erasure, encodedTreeCid: Cid, targetCid: Cid, params: EncodingParams
): Future[?!(ref seq[Cid], seq[Natural])] {.async: (raises: [CancelledError]).} =
  logScope:
    encodedTreeCid = encodedTreeCid
    targetCid = targetCid
    steps = params.steps
    roundedBlocks = params.rounded
    encodedBlocksCount = params.encodedBlocksCount

  var
    cids = seq[Cid].new()
    recoveredIndices = newSeq[Natural]()
    emptyBlock = newSeq[byte](params.blockSize.int)

  cids[].setLen(params.encodedBlocksCount)
  for step in 0 ..< params.steps:
    var
      data = new seq[seq[byte]]
      parityData = new seq[seq[byte]]
      recovered = new seq[seq[byte]]

    data[].setLen(params.ecK) # set len to K
    parityData[].setLen(params.ecM) # set len to M
    recovered[] = newSeqWith(params.ecK, newSeqWith(params.blockSize.int, 0'u8))

    let (dataPieces, parityPieces) =
      ?await self.prepareDecodingData(
        encodedTreeCid, params, step, data, parityData, cids, emptyBlock
      )

    if dataPieces + parityPieces < params.ecK:
      return failure(
        (ref InsufficientBlocksError)(
          msg:
            "Insufficient erasure pieces for decoding step " & $step & ": got " &
            $(dataPieces + parityPieces) & ", need " & $params.ecK
        )
      )

    if dataPieces >= params.ecK:
      trace "Retrieved all the required data blocks"
      continue

    trace "Erasure decoding data"
    ?await self.asyncDecode(params.blockSize.int, data, parityData, recovered)
    var blocks: seq[(bt.Block, Natural, ArchivistProof)]
    for i in 0 ..< params.ecK:
      let idx = i * params.steps + step
      if data[i].len <= 0 and not cids[idx].isEmpty:
        without blk =? bt.Block.new(recovered[i]), error:
          trace "Unable to create block!", exc = error.msg
          return failure(error)

        trace "Recovered block", cid = blk.cid, index = i
        self.networkStore.completeBlock(encodedTreeCid, idx, blk)

        cids[idx] = blk.cid
        blocks.add((blk, idx.Natural, nil))
        recoveredIndices.add(idx)

    trace "Storing recovered blocks", count = blocks.len
    ?await self.repoStore.putBlocks(targetCid, blocks)

  return (cids, recoveredIndices).success

proc decode*(
    self: Erasure, encoded: Manifest
): Future[?!Manifest] {.async: (raises: [CancelledError]).} =
  ## Decode a protected manifest into it's original
  ## manifest
  ##
  ## `encoded` - the encoded (protected) manifest to
  ##             be recovered
  ##

  logScope:
    treeCid = encoded.treeCid
    originalTreeCid = encoded.originalTreeCid

  trace "Preparing to decode dataset"

  let
    emptyCid = ?emptyCid(encoded.version, encoded.hcodec, encoded.codec)
    params = EncodingParams.initFromEncoded(encoded, emptyCid)

  var
    cids: ref seq[Cid]
    recoveredIndices: seq[Natural]

  ?await self.repoStore.withOverlay(
    encoded.originalTreeCid,
    status = Storing.some,
    body = proc(): Future[?!void] {.closure, async: (raises: [CancelledError]).} =
      let
        (cids, recoveredIndices) =
          ?await self.decodeInternal(encoded.treeCid, encoded.originalTreeCid, params)
        tree = ?ArchivistTree.init(cids[0 ..< encoded.originalBlocksCount])
        treeCid = ?tree.rootCid

      if treeCid != encoded.originalTreeCid:
        return failure(
          "Original tree root differs from the tree root computed out of recovered data"
        )

      let idxIter =
        Iter[Natural].new(recoveredIndices).filter((i: Natural) => i < tree.leavesCount)

      if err =? (await self.repoStore.putSomeProofs(tree, idxIter)).errorOption:
        return failure(err)

      trace "Successfully decoded original dataset"
      success(),
  )

  let decoded = Manifest.new(encoded)
  return decoded.success

proc repair*(
    self: Erasure, encoded: Manifest
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Repair a protected manifest by reconstructing the full dataset
  ##
  ## `encoded` - the encoded (protected) manifest to
  ##             be repaired
  ##
  ## TODO: there are several quirks to be aware of here -
  ## decode can only recreate original blocks, the resulting
  ## parity is not usable (AFAIK) as the original parity blocks
  ## so we need decode the original dataset first and then
  ## re-encode it to get valid parity blocks for the repaired manifest
  ##
  ## So the first decode is called with the original tree as it's overlay,
  ## the call to encode will create the protected overlay and manifest,
  ## this means that we need to properly handle cleanup of these overlays
  ## to avoid leaving garbage in the store
  ##

  logScope:
    treeCid = encoded.treeCid
    originalTreeCid = encoded.originalTreeCid

  trace "Preparing to repair dataset"

  let
    emptyCid = ?emptyCid(encoded.version, encoded.hcodec, encoded.codec)
    params = EncodingParams.initFromEncoded(encoded, emptyCid)

  ?await self.repoStore.withOverlay(
    encoded.originalTreeCid,
    status = Repairing.some,
    body = proc(): Future[?!void] {.closure, async: (raises: [CancelledError]).} =
      let
        (cids, _) =
          ?await self.decodeInternal(encoded.treeCid, encoded.originalTreeCid, params)
        tree = ?ArchivistTree.init(cids[0 ..< encoded.originalBlocksCount])
        treeCid = ?tree.rootCid

      if treeCid != encoded.originalTreeCid:
        return failure(
          "Original tree root differs from the tree root computed out of recovered data"
        )

      ?await self.repoStore.putAllProofs(tree)
      trace "Successfully repaired original dataset"
      success(),
  )

  # TODO: We don't get valid parity data from leopard,
  # so we need to do full re-encoding to get parity
  # blocks for a valid slot - this is higly inneficient
  # we need to either fix leopard or use another implementation
  let repaired =
    ?(await self.encode(encoded, encoded.ecK, encoded.ecM, encoded.protectedStrategy))

  trace "Successfully re-encoded original dataset"
  if repaired.treeCid != encoded.treeCid:
    return failure(
      "Original tree root differs from the repaired tree root encoded out of recovered data"
    )

  return success()

proc start*(self: Erasure) {.async.} =
  return

proc stop*(self: Erasure) {.async.} =
  return

proc new*(
    T: type Erasure,
    networkStore: BlockStore,
    repoStore: RepoStore,
    encoderProvider: EncoderProvider,
    decoderProvider: DecoderProvider,
    taskPool: Taskpool,
): Erasure =
  ## Create a new Erasure instance for encoding and decoding manifests
  ##
  Erasure(
    networkStore: networkStore,
    repoStore: repoStore,
    encoderProvider: encoderProvider,
    decoderProvider: decoderProvider,
    taskPool: taskPool,
  )
