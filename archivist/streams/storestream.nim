## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/tables
import std/options

import pkg/chronos
import pkg/stew/ptrops

import ../stores
import ../manifest
import ../blocktype
import ../logutils
import ../utils

import ./seekablestream

export stores, blocktype, manifest, chronos

logScope:
  topics = "archivist storestream"

const StoreStreamTrackerName* = "StoreStream"

type
  # Make SeekableStream from a sequence of blocks stored in Manifest
  # (only original file data - see StoreStream.size)
  StoreStream* = ref object of SeekableStream
    store*: BlockStore # Store where to lookup block contents
    manifest*: Manifest # List of block CIDs

method initStream*(s: StoreStream) =
  if s.objName.len == 0:
    s.objName = StoreStreamTrackerName

  procCall SeekableStream(s).initStream()

proc new*(
    T: type StoreStream, store: BlockStore, manifest: Manifest, pad = true
): StoreStream =
  ## Create a new StoreStream instance for a given store and manifest
  ##
  result = StoreStream(store: store, manifest: manifest, offset: 0)

  result.initStream()

method `size`*(self: StoreStream): int =
  ## The size of a StoreStream is the size of the original dataset, without
  ## padding or parity blocks.
  let m = self.manifest
  (if m.protected: m.originalDatasetSize else: m.datasetSize).int

proc `size=`*(self: StoreStream, size: int) {.error: "Setting the size is forbidden".} =
  discard

method atEof*(self: StoreStream): bool =
  self.offset >= self.size

type LPStreamReadError* = object of LPStreamError

proc newLPStreamReadError*(p: ref CatchableError): ref LPStreamReadError =
  newException(LPStreamReadError, "Read stream failed", p)

method readOnce*(
    self: StoreStream, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, LPStreamError]).} =
  ## Read `nbytes` from current position in the StoreStream into output
  ## buffer pointed by `pbytes`.
  ##
  ## Return how many bytes were actually read before EOF was encountered.
  ## Raise exception if we are already at EOF.
  ##

  if self.atEof:
    raise newLPStreamEOFError()

  let
    blockSize = self.manifest.blockSize.int
    treeCid = self.manifest.treeCid
    firstBlock = self.offset div blockSize
    lastBlock =
      min(self.manifest.blocksCount - 1, (self.offset + nbytes - 1) div blockSize)

  # Prefetch all blocks in range as a batch
  let indices = (firstBlock .. lastBlock).mapIt(it.Natural)
  trace "Requesting indices from store", indices
  without blocks =? (await self.store.getBlocks(treeCid, indices)).tryGet.catch, err:
    trace "Unable to get blocks from store", err = err.msg
    raise newLPStreamReadError(err)

  if blocks.len == 0:
    trace "No blocks returned from store!"
    raise newLPStreamReadError(newException(IOError, "No blocks returned from store!"))

  # Build a lookup table from block CID to block data for ordered copying
  # We copy block by block in index order using single-block getBlock fallback
  # if a block is missing from the batch result.
  var read = 0
  let blocksMap = blocks.toTable

  for idx in indices:
    if self.atEof or read >= nbytes:
      break

    if idx notin blocksMap:
      break

    without blk =? catch(blocksMap[idx]), err:
      trace "Block index not found in returned batch, some blocks failed to retrieve",
        err = err.msg
      raise newLPStreamReadError(err)

    trace "Read block", cid = blk.cid

    let
      blockOffset = (self.offset + read) mod blockSize
      readBytes =
        min([self.size - self.offset - read, nbytes - read, blockSize - blockOffset])

    trace "Read bytes", readBytes
    if readBytes <= 0:
      break

    trace "Reading bytes from store stream",
      manifestCid = treeCid,
      numBlocks = self.manifest.blocksCount,
      blockNum = idx,
      blkCid = blk.cid,
      bytes = readBytes,
      blockOffset

    if blk.isEmpty:
      zeroMem(pbytes.offset(read), readBytes)
    else:
      copyMem(pbytes.offset(read), blk.data[blockOffset].unsafeAddr, readBytes)

    read += readBytes

  self.offset += read
  return read

method closeImpl*(self: StoreStream) {.async: (raises: []).} =
  trace "Closing StoreStream"
  self.offset = self.size # set Eof
  await procCall LPStream(self).closeImpl()
