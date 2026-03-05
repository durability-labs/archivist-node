## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/sequtils
import std/sets

import pkg/chronos
import pkg/libp2p
import pkg/questionable/results

import ../blocktype
import ../blockexchange
import ../logutils
import ../manifest
import ../merkletree
import ../utils/asyncheapqueue
import ../utils/safeasynciter
import ./blockstore

export blockstore, blockexchange, asyncheapqueue

logScope:
  topics = "archivist networkstore"

type NetworkStore* = ref object of BlockStore
  engine*: BlockExcEngine # blockexc decision engine
  localStore*: BlockStore # local block store

method getBlocks*(
    self: NetworkStore, cids: seq[Cid]
): Future[?!seq[Block]] {.async: (raises: [CancelledError]).} =
  ## Get multiple blocks by CID (no tree context).
  ##
  ## Fetches all locally available blocks in one batch call.
  ## For any missing blocks, falls back to individual network requests
  ## (concurrent, one per missing CID).
  ##

  let
    uniqueCids = cids.toHashSet.toSeq
    localBlocks = ?await self.localStore.getBlocks(uniqueCids)

  if localBlocks.len == uniqueCids.len:
    return success(localBlocks)

  # Find CIDs not returned locally
  let localCids = localBlocks.mapIt(it.cid).toHashSet
  var
    toRequestCids = (uniqueCids.toHashSet - localCids).toSeq
    requests: seq[Future[?!Block]]

  for cid in toRequestCids:
    requests.add(self.engine.requestBlock(BlockAddress.init(cid)))

  var allBlocks = localBlocks
  while requests.len > 0:
    without completedFut =? catch(await one(requests)), err:
      if err of CancelledError:
        raise (ref CancelledError)(err)
      error "Unable to get block from exchange engine", err = err.msg
      break

    let idx = requests.find(completedFut)
    requests.del(idx)

    without blk =? catch(await completedFut).flatten, err:
      if err of CancelledError:
        raise (ref CancelledError)(err)
          # need to wrap, otherwise it will be reinterpreted as CatchableError
      error "Unable to get block from exchange engine", err = err.msg
      continue

    allBlocks.add(blk)

  success(allBlocks)

method getBlock*(
    self: NetworkStore, cid: Cid
): Future[?!Block] {.async: (raises: [CancelledError]).} =
  ## Get a block from the blockstore
  ##

  without blk =? (await self.localStore.getBlock(cid)), err:
    if not (err of BlockNotFoundError):
      error "Error getting block from local store", cid, err = err.msg
      return failure err

    without newBlock =? (await self.engine.requestBlock(BlockAddress.init(cid))), err:
      error "Unable to get block from exchange engine", cid, err = err.msg
      return failure err

    return success newBlock

  return success blk

method getBlock*(
    self: NetworkStore, treeCid: Cid, index: Natural
): Future[?!Block] {.async: (raises: [CancelledError]).} =
  ## Get a block from the blockstore
  ##

  without blk =? (await self.localStore.getBlock(treeCid, index)), err:
    if not (err of BlockNotFoundError):
      error "Error getting block from local store", treeCid, index, err = err.msg
      return failure err

    without newBlock =?
      (await self.engine.requestBlock(BlockAddress.init(treeCid, index))), err:
      error "Unable to get block from exchange engine", treeCid, index, err = err.msg
      return failure err

    return success newBlock

  return success blk

method getBlocks*(
    self: NetworkStore, treeCid: Cid, indices: seq[Natural]
): Future[?!seq[(Natural, Block)]] {.async: (raises: [CancelledError]).} =
  ## Get multiple blocks by tree CID and indices.
  ##
  ## Fetches all locally available blocks in one batch call.
  ## For any missing blocks, falls back to individual network requests
  ## (concurrent, one per missing index).
  ##

  let
    indices = indices.toHashSet.toSeq
    localBlocks = ?await self.localStore.getBlocks(treeCid, indices)

  trace "Got local blocks", count = localBlocks.len

  # If all indices returned, we're done
  if localBlocks.len == indices.len:
    return success(localBlocks)

  # check get the diff of the still to retrieve indices from the network
  var
    toRequestIdxs = (indices.toHashSet - localBlocks.mapIt(it[0]).toHashSet).toSeq
    requests: seq[Future[?!Block]]

  for idx in toRequestIdxs:
    requests.add(self.engine.requestBlock(BlockAddress.init(treeCid, idx)))

  var allBlocks = localBlocks
  while requests.len > 0:
    without completedFut =? catch(await one(requests)), err:
      if err of CancelledError:
        raise (ref CancelledError)(err)
      error "Unable to get block from exchange engine", treeCid, err = err.msg
      break

    let
      idx = requests.find(completedFut)
      originalIdx = toRequestIdxs[idx]
    requests.del(idx)
    toRequestIdxs.del(idx)

    without blk =? catch(await completedFut).flatten, err:
      if err of CancelledError:
        raise (ref CancelledError)(err)
      error "Unable to get block from exchange engine", treeCid, err = err.msg
      continue

    allBlocks.add((originalIdx, blk))

  success allBlocks

method completeBlock*(self: NetworkStore, treeCid: Cid, index: Natural, blk: Block) =
  self.engine.completeBlock(BlockAddress.init(treeCid, index), blk)

method putBlock*(
    self: NetworkStore, blk: Block, ttl = Duration.none
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Store block locally and notify the network
  ##
  let res = await self.localStore.putBlock(blk, ttl)
  if res.isErr:
    return res

  await self.engine.resolveBlocks(@[blk])
  return success()

method putBlocks*(
    self: NetworkStore, treeCid: Cid, items: seq[(Block, Natural, ArchivistProof)]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Store leafs and blocks locally and notify the network
  ##

  ?await self.localStore.putBlocks(treeCid, items)
  await self.engine.resolveBlocks(items.mapIt(it[0]))
  return success()

method putCidsAndProofs*(
    self: NetworkStore, treeCid: Cid, items: seq[(Natural, Cid, ArchivistProof)]
): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
  self.localStore.putCidsAndProofs(treeCid, items)

method listBlocks*(
    self: NetworkStore, blockType = BlockType.Manifest
): Future[?!SafeAsyncIter[Cid]] {.async: (raw: true, raises: [CancelledError]).} =
  self.localStore.listBlocks(blockType)

method delBlock*(
    self: NetworkStore, cid: Cid
): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
  ## Delete a block from the blockstore
  ##

  trace "Deleting block from network store", cid
  return self.localStore.delBlock(cid)

{.pop.}

method hasBlock*(
    self: NetworkStore, cid: Cid
): Future[?!bool] {.async: (raises: [CancelledError]).} =
  ## Check if the block exists in the blockstore
  ##

  trace "Checking network store for block existence", cid
  return await self.localStore.hasBlock(cid)

method hasBlocks*(
    self: NetworkStore, tree: Cid, indices: seq[Natural]
): Future[?!seq[(Natural, bool)]] {.async: (raw: true, raises: [CancelledError]).} =
  ## Check if multiple blocks exist in the blockstore
  ##

  self.localStore.hasBlocks(tree, indices)

method storeManifest*(
    self: NetworkStore, manifest: Manifest
): Future[?!Block] {.async: (raw: true, raises: [CancelledError]).} =
  ## Store a manifest to the blockstore
  ##

  self.localStore.storeManifest(manifest)

method fetchManifest*(
    self: NetworkStore, cid: Cid
): Future[?!Manifest] {.async: (raises: [CancelledError]).} =
  ## Fetch a manifest from the blockstore by CID
  ##

  without manifest =? (await self.localStore.fetchManifest(cid)), err:
    if err of BlockNotFoundError:
      without manifestBlk =? (await self.engine.requestBlock(cid)), err:
        error "Unable to fetch manifest block!", err = err.msg
        return failure(err)

      return Manifest.decode(manifestBlk)

  return success manifest

method getCid*(
    self: NetworkStore, treeCid: Cid, index: Natural
): Future[?!Cid] {.async: (raw: true, raises: [CancelledError]).} =
  ## Get a block CID given a tree and index
  ##

  self.localStore.getCid(treeCid, index)

method putCellCidsAndProofs*(
    self: NetworkStore, treeCid: Cid, items: seq[(Natural, Cid, Cid, ArchivistProof)]
): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
  ## Put multiple cell CIDs and proofs as a batch
  ##

  self.localStore.putCellCidsAndProofs(treeCid, items)

method delBlocks*(
    self: NetworkStore, treeCid: Cid, indices: seq[Natural]
): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
  ## Delete multiple blocks by tree CID and indices
  ##

  self.localStore.delBlocks(treeCid, indices)

method getBlocksAndProofs*(
    self: NetworkStore, treeCid: Cid, indices: seq[Natural]
): Future[?!seq[(Natural, Block, ArchivistProof)]] {.async: (raises: [CancelledError]).} =
  ## Get multiple blocks and proofs.
  ##
  ## Fetches all locally available blocks in one batch call.
  ## For any missing blocks, falls back to individual network requests
  ## (concurrent, one per missing index). After the engine persists a
  ## network-fetched block, we retrieve the proof from the local store.
  ##
  ## TODO: The engine should return both block and proof directly via a
  ## future signaling mechanism, with the caller handling persistence.
  ## Currently the engine persists internally, so we must re-query the
  ## store for the proof after each network fetch.
  ##

  let
    indices = indices.toHashSet.toSeq
    localBlocks = ?await self.localStore.getBlocksAndProofs(treeCid, indices)

  trace "Got local blocks and proofs", count = localBlocks.len

  # If all indices returned, we're done
  if localBlocks.len == indices.len:
    return success(localBlocks)

  # Check the diff of the still to retrieve indices from the network
  var
    toRequestIdxs = (indices.toHashSet - localBlocks.mapIt(it[0]).toHashSet).toSeq
    requests: seq[Future[?!Block]]

  for idx in toRequestIdxs:
    requests.add(self.engine.requestBlock(BlockAddress.init(treeCid, idx)))

  var allBlocks = localBlocks
  while requests.len > 0:
    without completedFut =? catch(await one(requests)), err:
      if err of CancelledError:
        raise (ref CancelledError)(err)
      error "Unable to get block from exchange engine", treeCid, err = err.msg
      break

    let
      idx = requests.find(completedFut)
      originalIdx = toRequestIdxs[idx]

    requests.del(idx)
    toRequestIdxs.del(idx)

    without blk =? catch(await completedFut).flatten, err:
      if err of CancelledError:
        raise (ref CancelledError)(err)
      error "Unable to get block from exchange engine", treeCid, err = err.msg
      continue

    # TODO: The engine should return (Block, ?Proof), but we haven't yet refactored that,
    # however, it does persist it on disk, so we can fetch from the local store.
    # Once the engine is properly refactored for batch requests and returning the correct
    # combination of (Block, Proof), we'll need to change this.
    let blockProof = ?await self.localStore.getBlocksAndProofs(treeCid, @[originalIdx])
    if blockProof.len == 0:
      warn "Skipping block and proof, couldn't resolve",
        treeCid, index = originalIdx, cid = blk.cid
      continue

    allBlocks.add(blockProof[0])

  success allBlocks

method getCidsAndProofs*(
    self: NetworkStore, treeCid: Cid, indices: seq[Natural]
): Future[?!seq[(Cid, ArchivistProof)]] {.async: (raw: true, raises: [CancelledError]).} =
  ## Get multiple CIDs and proofs
  ##

  self.localStore.getCidsAndProofs(treeCid, indices)

method putBlocks*(
    self: NetworkStore, treeCid: Cid, blocks: seq[(Natural, Block)]
): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
  ## Put multiple blocks without proofs
  ##

  self.localStore.putBlocks(treeCid, blocks)

method close*(self: NetworkStore): Future[void] {.async: (raises: []).} =
  ## Close the underlying local blockstore
  ##

  if not self.localStore.isNil:
    await self.localStore.close

proc new*(
    T: type NetworkStore, engine: BlockExcEngine, localStore: BlockStore
): NetworkStore =
  ## Create new instance of a NetworkStore
  ##

  NetworkStore(localStore: localStore, engine: engine)
