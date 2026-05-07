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

proc collectDeliveries(
    requests: seq[BlockHandle]
): Future[seq[BlockDelivery]] {.async: (raises: [CancelledError]).} =
  var
    pending = requests
    deliveries: seq[BlockDelivery]

  while pending.len > 0:
    without completedFut =? catchAsync(await one(pending)), err:
      error "Unable to get block from exchange engine", err = err.msg
      break

    pending.del(pending.find(completedFut))

    without delivery =? catchAsync(await completedFut), err:
      error "Unable to get block from exchange engine", err = err.msg
      continue

    deliveries.add(delivery)

  return deliveries

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
    uniqueCids = cids.deduplicate()
    localBlocks = ?await self.localStore.getBlocks(uniqueCids)
  if localBlocks.len == uniqueCids.len:
    return success(localBlocks)

  var localCids: HashSet[Cid]
  for blk in localBlocks:
    localCids.incl(blk.cid)

  var addresses: seq[BlockAddress]
  for cid in uniqueCids:
    if cid notin localCids:
      addresses.add(BlockAddress.init(cid))

  var requests = ?self.engine.requestDeliveries(addresses)
  var allBlocks = localBlocks
  for delivery in await collectDeliveries(requests):
    allBlocks.add(delivery.blk)

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

    let handle = ?self.engine.requestDelivery(BlockAddress.init(cid))
    without delivery =? catchAsync(await handle), err:
      error "Unable to get block from exchange engine", cid, err = err.msg
      return failure err

    return success delivery.blk

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

    let handle = ?self.engine.requestDelivery(BlockAddress.init(treeCid, index))
    without delivery =? catchAsync(await handle), err:
      error "Unable to get block from exchange engine", treeCid, index, err = err.msg
      return failure err

    return success delivery.blk

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
    uniqueIndices = indices.deduplicate()
    localBlocks = ?await self.localStore.getBlocks(treeCid, uniqueIndices)

  trace "Got local blocks", count = localBlocks.len

  if localBlocks.len == uniqueIndices.len:
    return success(localBlocks)

  var localIndices: HashSet[Natural]
  for item in localBlocks:
    localIndices.incl(item[0])

  var addresses: seq[BlockAddress]
  for index in uniqueIndices:
    if index notin localIndices:
      addresses.add(BlockAddress.init(treeCid, index))

  var requests = ?self.engine.requestDeliveries(addresses)
  var allBlocks = localBlocks
  for delivery in await collectDeliveries(requests):
    allBlocks.add((delivery.address.index, delivery.blk))

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

  var deliveries: seq[BlockDelivery]
  for (blk, index, proof) in items:
    let proofOpt = if proof.isNil: ArchivistProof.none else: proof.some

    deliveries.add(
      BlockDelivery(
        address: BlockAddress.init(treeCid, index), blk: blk, proof: proofOpt
      )
    )

  await self.engine.resolveBlocks(deliveries)

  return success()

method putCidsAndProofs*(
    self: NetworkStore, treeCid: Cid, items: seq[(Natural, Cid, ArchivistProof)]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ?await self.localStore.putCidsAndProofs(treeCid, items)

  let storedItems =
    ?await self.localStore.getBlocksAndProofs(treeCid, items.mapIt(it[0]))
  var deliveries: seq[BlockDelivery]
  for item in storedItems:
    if item[2].isNil:
      continue

    deliveries.add(
      BlockDelivery(
        address: BlockAddress.init(treeCid, item[0]), blk: item[1], proof: item[2].some
      )
    )

  if deliveries.len > 0:
    await self.engine.resolveBlocks(deliveries)

  success()

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
      let handle = ?self.engine.requestDelivery(BlockAddress.init(cid))
      without delivery =? catchAsync(await handle), err:
        error "Unable to fetch manifest block!", err = err.msg
        return failure(err)

      return Manifest.decode(delivery.blk)

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
  ## For missing blocks, requests proof-bearing deliveries from BlockExchange
  ## and uses the validated delivery proof directly.
  ##

  let
    uniqueIndices = indices.deduplicate()
    localBlocks = ?await self.localStore.getBlocksAndProofs(treeCid, uniqueIndices)

  trace "Got local blocks and proofs", count = localBlocks.len

  if localBlocks.len == uniqueIndices.len:
    return success(localBlocks)

  var localIndices: HashSet[Natural]
  for item in localBlocks:
    localIndices.incl(item[0])

  var addresses: seq[BlockAddress]
  for index in uniqueIndices:
    if index notin localIndices:
      addresses.add(BlockAddress.init(treeCid, index))

  var requests = ?self.engine.requestDeliveries(addresses)
  var allBlocks = localBlocks
  for delivery in await collectDeliveries(requests):
    if not delivery.address.leaf:
      warn "Skipping non-leaf delivery for leaf request", address = delivery.address
      continue

    without proof =? delivery.proof:
      warn "Skipping leaf delivery without proof", address = delivery.address
      continue

    allBlocks.add((delivery.address.index, delivery.blk, proof))

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
