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
    ecK: Natural
    ecM: Natural
    rounded: Natural
    steps: Natural
    blocksCount: Natural
    strategy: StrategyType

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
    self: Erasure, manifest: Manifest, indices: seq[int]
): AsyncIter[(?!bt.Block, int)] =
  ## Get pending blocks iterator
  ##
  var pendingBlocks: seq[Future[(?!bt.Block, int)]] = @[]

  proc attachIndex(
      fut: Future[?!bt.Block], i: int
  ): Future[(?!bt.Block, int)] {.async.} =
    ## avoids closure capture issues
    return (await fut, i)

  for blockIndex in indices:
    # request blocks from the store
    let fut =
      self.networkStore.getBlock(BlockAddress.init(manifest.treeCid, blockIndex))
    pendingBlocks.add(attachIndex(fut, blockIndex))

  proc isFinished(): bool =
    pendingBlocks.len == 0

  proc genNext(): Future[(?!bt.Block, int)] {.async.} =
    let completedFut = await one(pendingBlocks)
    if (let i = pendingBlocks.find(completedFut); i >= 0):
      pendingBlocks.del(i)
      return await completedFut
    else:
      let (_, index) = await completedFut
      raise newException(
        CatchableError,
        "Future for block id not found, tree cid: " & $manifest.treeCid & ", index: " &
          $index,
      )

  AsyncIter[(?!bt.Block, int)].new(genNext, isFinished)

proc prepareEncodingData(
    self: Erasure,
    manifest: Manifest,
    params: EncodingParams,
    step: Natural,
    data: ref seq[seq[byte]],
    cids: ref seq[Cid],
    emptyBlock: seq[byte],
): Future[?!Natural] {.async: (raises: [CancelledError]).} =
  ## Prepare data for encoding
  ##

  let
    strategy =
      ?catch(
        params.strategy.init(
          firstIndex = 0, lastIndex = params.rounded - 1, iterations = params.steps
        )
      )
    indices = toSeq(?catch(strategy.getIndices(step)))
    pendingBlocksIter =
      self.getPendingBlocks(manifest, indices.filterIt(it < manifest.blocksCount))

  var resolved = 0
  for fut in pendingBlocksIter:
    let
      (blkOrErr, idx) = ?catch(await fut)
      blk = ?blkOrErr

    let pos = indexToPos(params.steps, idx, step)
    data[pos] = if blk.isEmpty: emptyBlock else: blk.data
    cids[idx] = blk.cid

    resolved.inc()

  for idx in indices.filterIt(it >= manifest.blocksCount):
    let pos = indexToPos(params.steps, idx, step)
    trace "Padding with empty block", idx
    data[pos] = emptyBlock
    without emptyBlockCid =? emptyCid(manifest.version, manifest.hcodec, manifest.codec),
      err:
      return failure(err)
    cids[idx] = emptyBlockCid

  success(resolved.Natural)

proc prepareDecodingData(
    self: Erasure,
    encoded: Manifest,
    step: Natural,
    data: ref seq[seq[byte]],
    parityData: ref seq[seq[byte]],
    cids: ref seq[Cid],
    emptyBlock: seq[byte],
): Future[?!(Natural, Natural)] {.async: (raises: [CancelledError]).} =
  ## Prepare data for decoding
  ## `encoded`    - the encoded manifest
  ## `step`       - the current step
  ## `data`       - the data to be prepared
  ## `parityData` - the parityData to be prepared
  ## `cids`       - cids of prepared data
  ## `emptyBlock` - the empty block to be used for padding
  ##

  let
    strategy =
      ?catch(
        encoded.protectedStrategy.init(
          firstIndex = 0,
          lastIndex = encoded.blocksCount - 1,
          iterations = encoded.steps,
        )
      )
    indices = toSeq(?catch(strategy.getIndices(step)))
    pendingBlocksIter = self.getPendingBlocks(encoded, indices)

  var
    dataPieces = 0
    parityPieces = 0
    resolved = 0
  for fut in pendingBlocksIter:
    # Continue to receive blocks until we have just enough for decoding
    # or no more blocks can arrive
    if resolved >= encoded.ecK:
      break

    let (blkOrErr, idx) = ?catch(await fut)
    without blk =? blkOrErr, err:
      trace "Failed retrieving a block", idx, treeCid = encoded.treeCid, msg = err.msg
      continue

    let pos = indexToPos(encoded.steps, idx, step)

    logScope:
      cid = blk.cid
      idx = idx
      pos = pos
      step = step
      empty = blk.isEmpty

    cids[idx] = blk.cid
    if idx >= encoded.rounded:
      trace "Retrieved parity block"
      parityData[pos - encoded.ecK] = if blk.isEmpty: emptyBlock else: blk.data
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
    blocksCount = rounded + (steps * ecM)

  success EncodingParams(
    ecK: ecK,
    ecM: ecM,
    rounded: rounded,
    steps: steps,
    blocksCount: blocksCount,
    strategy: strategy,
  )

proc leopardEncodeTask(tp: Taskpool, task: ptr EncodeTask) {.gcsafe.} =
  # Task suitable for running in taskpools - look, no GC!
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
    self: Erasure, manifest: Manifest, params: EncodingParams
): Future[?!Manifest] {.async: (raises: [CancelledError]).} =
  ## Encode blocks pointed to by the protected manifest
  ##
  ## `manifest` - the manifest to encode
  ##
  logScope:
    steps = params.steps
    rounded_blocks = params.rounded
    blocks_count = params.blocksCount
    ecK = params.ecK
    ecM = params.ecM

  var
    cids = seq[Cid].new()
    emptyBlock = newSeq[byte](manifest.blockSize.int)
    cleanupTmp = false

  cids[].setLen(params.blocksCount)

  let tempTreeCid = ?await self.repoStore.createTmpOverlay()
  defer:
    if cleanupTmp:
      if err =? (await self.repoStore.dropOverlay(tempTreeCid)).errorOption:
        trace "Unable to drop temporary overlay", tempTreeCid, err = err.msg

  for step in 0 ..< params.steps:
    # TODO: Don't allocate a new seq every time, allocate once and zero out
    var
      data = new seq[seq[byte]] # number of blocks to encode
      parity = new seq[seq[byte]]

    data[].setLen(params.ecK)
    parity[] = newSeqWith(params.ecM, newSeqWith(manifest.blockSize.int, 0'u8))

    # TODO: this is a tight blocking loop so we sleep here to allow
    # other events to be processed, this should be addressed
    # by threading
    let resolved =
      ?await self.prepareEncodingData(manifest, params, step, data, cids, emptyBlock)

    trace "Erasure coding data", data = data[].len
    ?await self.asyncEncode(manifest.blockSize.int, data, parity)
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
    ?await self.repoStore.putLeafsAndBlocks(tempTreeCid, blocks)

  cleanupTmp = true

  let
    tree = ?ArchivistTree.init(cids[])
    treeCid = ?tree.rootCid
    encodedManifest = Manifest.new(
      manifest = manifest,
      treeCid = treeCid,
      datasetSize = (manifest.blockSize.int * params.blocksCount).NBytes,
      ecK = params.ecK,
      ecM = params.ecM,
      strategy = params.strategy,
    )

  ?await self.repoStore.finalizeOverlay(tempTreeCid, treeCid)
  cleanupTmp = false

  for index, cid in cids[]:
    ?await self.repoStore.putCidAndProof(treeCid, index, cid, ?tree.getProof(index))

  trace "Encoded data successfully", treeCid, blocksCount = params.blocksCount
  success encodedManifest

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
    params = ?EncodingParams.init(manifest, blocks.int, parity.int, strategy)
    encodedManifest = ?await self.encodeData(manifest, params)

  return success encodedManifest

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
    self: Erasure, encoded: Manifest
): Future[?!(ref seq[Cid], seq[Natural])] {.async: (raises: [CancelledError]).} =
  logScope:
    steps = encoded.steps
    rounded_blocks = encoded.rounded
    new_manifest = encoded.blocksCount

  var
    cids = seq[Cid].new()
    recoveredIndices = newSeq[Natural]()
    emptyBlock = newSeq[byte](encoded.blockSize.int)

  cids[].setLen(encoded.blocksCount)
  for step in 0 ..< encoded.steps:
    var
      data = new seq[seq[byte]]
      parityData = new seq[seq[byte]]
      recovered = new seq[seq[byte]]

    data[].setLen(encoded.ecK) # set len to K
    parityData[].setLen(encoded.ecM) # set len to M
    recovered[] = newSeqWith(encoded.ecK, newSeqWith(encoded.blockSize.int, 0'u8))

    let (dataPieces, _) =
      ?await self.prepareDecodingData(encoded, step, data, parityData, cids, emptyBlock)

    if dataPieces >= encoded.ecK:
      trace "Retrieved all the required data blocks"
      continue

    trace "Erasure decoding data"
    ?await self.asyncDecode(encoded.blockSize.int, data, parityData, recovered)
    var blocks: seq[(bt.Block, Natural, ArchivistProof)]
    for i in 0 ..< encoded.ecK:
      let idx = i * encoded.steps + step
      if data[i].len <= 0 and not cids[idx].isEmpty:
        without blk =? bt.Block.new(recovered[i]), error:
          trace "Unable to create block!", exc = error.msg
          return failure(error)

        trace "Recovered block", cid = blk.cid, index = i
        self.networkStore.completeBlock(BlockAddress.init(encoded.treeCid, idx), blk)

        cids[idx] = blk.cid
        blocks.add((blk, idx.Natural, nil))
        recoveredIndices.add(idx)

    trace "Storing recovered blocks", count = blocks.len
    ?await self.repoStore.putLeafsAndBlocks(encoded.treeCid, blocks)

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

  let
    (cids, recoveredIndices) = ?await self.decodeInternal(encoded)
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

  let decoded = Manifest.new(encoded)

  return decoded.success

proc repair*(self: Erasure, encoded: Manifest): Future[?!void] {.async.} =
  ## Repair a protected manifest by reconstructing the full dataset
  ##
  ## `encoded` - the encoded (protected) manifest to
  ##             be repaired
  ##

  let
    (cids, _) = ?await self.decodeInternal(encoded)
    tree = ?ArchivistTree.init(cids[0 ..< encoded.originalBlocksCount])
    treeCid = ?tree.rootCid

  if treeCid != encoded.originalTreeCid:
    return failure(
      "Original tree root differs from the tree root computed out of recovered data"
    )

  ?await self.repoStore.putAllProofs(tree)
  let repaired =
    ?(
      await self.encode(
        Manifest.new(encoded), encoded.ecK, encoded.ecM, encoded.protectedStrategy
      )
    )

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
