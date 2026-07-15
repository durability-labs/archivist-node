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
import pkg/metrics
import pkg/questionable/results

import ../blocktype
import ../blockexchange
import ../errors
import ../logutils
import ../manifest
import ../merkletree
import ../utils/asyncheapqueue
import ../utils/safeasynciter
import ./blockstore

export blockstore, blockexchange, asyncheapqueue

logScope:
  topics = "archivist networkstore"

declareCounter(
  archivist_networkstore_blocks_requested, "Total blocks requested from NetworkStore"
)
declareCounter(
  archivist_networkstore_blocks_local, "Total blocks served from local store"
)
declareCounter(
  archivist_networkstore_blocks_network, "Total blocks fetched via network"
)
declareCounter(
  archivist_networkstore_blocks_missed, "Total blocks not found locally or via network"
)

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
    uniqueCids = cids.deduplicate()
    localBlocks = ?await self.localStore.getBlocks(uniqueCids)
  archivist_networkstore_blocks_requested.inc(uniqueCids.len.int64)
  archivist_networkstore_blocks_local.inc(localBlocks.len.int64)

  if localBlocks.len == uniqueCids.len:
    return success(localBlocks)

  var localCids: HashSet[Cid]
  for blk in localBlocks:
    localCids.incl(blk.cid)

  var addresses: seq[BlockAddress]
  for cid in uniqueCids:
    if cid notin localCids:
      addresses.add(BlockAddress.init(cid))

  archivist_networkstore_blocks_network.inc(addresses.len.int64)
  let
    deliveries = ?self.engine.requestDeliveries(addresses)
    (succeeded, failed) = await allFinishedFailed[BlockDelivery](deliveries)

  archivist_networkstore_blocks_missed.inc(failed.len.int64)
  let networkBlocks = succeeded.mapIt(it.value.blk)
  success(localBlocks & networkBlocks)

method getBlock*(
    self: NetworkStore, cid: Cid
): Future[?!Block] {.async: (raises: [CancelledError]).} =
  ## Get a block from the blockstore
  ##

  without blk =? (await self.localStore.getBlock(cid)), err:
    if not (err of BlockNotFoundError):
      error "Error getting block from local store", cid, err = err.msg
      return failure err

    let delivery =
      ?catchAsync(await (?self.engine.requestDelivery(BlockAddress.init(cid))))
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

    let delivery =
      ?catchAsync(
        await (?self.engine.requestDelivery(BlockAddress.init(treeCid, index)))
      )
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

  archivist_networkstore_blocks_requested.inc(uniqueIndices.len.int64)
  archivist_networkstore_blocks_local.inc(localBlocks.len.int64)
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

  archivist_networkstore_blocks_network.inc(addresses.len.int64)
  let
    treeDeliveries = ?self.engine.requestDeliveries(addresses)
    (succeeded, failed) = await allFinishedFailed[BlockDelivery](treeDeliveries)

  archivist_networkstore_blocks_missed.inc(failed.len.int64)
  let treeNetworkBlocks = succeeded.mapIt((it.value.address.index, it.value.blk))
  success(localBlocks & treeNetworkBlocks)

method completeBlocks*(
    self: NetworkStore, treeCid: Cid, blocks: seq[(Natural, Block)]
): Future[void] {.async: (raises: [CancelledError]).} =
  var deliveries: seq[BlockDelivery]
  for (index, blk) in blocks:
    deliveries.add(BlockDelivery(address: BlockAddress.init(treeCid, index), blk: blk))

  await self.engine.completeBlocks(deliveries)

method completeBlock*(
    self: NetworkStore, treeCid: Cid, index: Natural, blk: Block
): Future[void] {.async: (raises: [CancelledError]).} =
  await self.completeBlocks(treeCid, @[(index, blk)])

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

  await self.engine.completeBlocks(deliveries)

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
    await self.engine.completeBlocks(deliveries)

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
      let delivery =
        ?catchAsync(await (?self.engine.requestDelivery(BlockAddress.init(cid))))
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

  var blocks: seq[(Natural, Block, ArchivistProof)]
  let
    deliveries = ?self.engine.requestDeliveries(addresses)
    (succeeded, failed) = await allFinishedFailed[BlockDelivery](deliveries)

  archivist_networkstore_blocks_missed.inc(failed.len.int64)
  for delivery in succeeded.mapIt(it.value):
    if not delivery.address.leaf:
      warn "Skipping non-leaf delivery for leaf request", address = delivery.address
      continue

    without proof =? delivery.proof:
      warn "Skipping leaf delivery without proof", address = delivery.address
      continue

    blocks.add((delivery.address.index, delivery.blk, proof))

  success(localBlocks & blocks)

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
