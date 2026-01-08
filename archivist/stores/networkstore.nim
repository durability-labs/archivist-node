## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import pkg/chronos
import pkg/libp2p
import pkg/questionable/results

import ../clock
import ../blocktype
import ../blockexchange
import ../logutils
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

method getBlock*(
    self: NetworkStore, address: BlockAddress
): Future[?!Block] {.async: (raises: [CancelledError]).} =
  without blk =? (await self.localStore.getBlock(address)), err:
    if not (err of BlockNotFoundError):
      error "Error getting block from local store", address, err = err.msg
      return failure err

    without newBlock =? (await self.engine.requestBlock(address)), err:
      error "Unable to get block from exchange engine", address, err = err.msg
      return failure err

    return success newBlock

  return success blk

method getBlock*(
    self: NetworkStore, cid: Cid
): Future[?!Block] {.async: (raw: true, raises: [CancelledError]).} =
  ## Get a block from the blockstore
  ##

  self.getBlock(BlockAddress.init(cid))

method getBlock*(
    self: NetworkStore, treeCid: Cid, index: Natural
): Future[?!Block] {.async: (raw: true, raises: [CancelledError]).} =
  ## Get a block from the blockstore
  ##

  self.getBlock(BlockAddress.init(treeCid, index))

method completeBlock*(self: NetworkStore, address: BlockAddress, blk: Block) =
  self.engine.completeBlock(address, blk)

method putBlock*(
    self: NetworkStore, blk: Block
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Store block locally and notify the network
  ## NOTE: ttl parameter removed - expiry is now managed at overlay level
  ##
  let res = await self.localStore.putBlock(blk)
  if res.isErr:
    return res

  await self.engine.resolveBlocks(@[blk])
  return success()

method putCidAndProof*(
    self: NetworkStore,
    treeCid: Cid,
    index: Natural,
    blockCid: Cid,
    proof: ArchivistProof,
): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
  self.localStore.putCidAndProof(treeCid, index, blockCid, proof)

method getCidAndProof*(
    self: NetworkStore, treeCid: Cid, index: Natural
): Future[?!(Cid, ArchivistProof)] {.async: (raw: true, raises: [CancelledError]).} =
  ## Get a block proof from the blockstore
  ##

  self.localStore.getCidAndProof(treeCid, index)

# NOTE: ensureExpiry methods removed - expiry is now managed at overlay level
# See design doc v3.8 Section 12 "Overlay Lifecycle & Maintenance"

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

method hasBlock*(
    self: NetworkStore, tree: Cid, index: Natural
): Future[?!bool] {.async: (raises: [CancelledError]).} =
  ## Check if the block exists in the blockstore
  ##
  trace "Checking network store for block existence", tree, index
  return await self.localStore.hasBlock(tree, index)

###########################################################
# Batch operations (temporary - will be replaced by DatasetManager)
###########################################################

method putBlocks*(
    self: NetworkStore, blocks: seq[Block]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Put multiple blocks - delegates to localStore
  ?await self.localStore.putBlocks(blocks)
  await self.engine.resolveBlocks(blocks)
  success()

method getBlocks*(
    self: NetworkStore, addresses: seq[BlockAddress]
): Future[?!seq[Block]] {.async: (raw: true, raises: [CancelledError]).} =
  ## Get multiple blocks - delegates to localStore
  ## TODO: Add network fallback for missing blocks
  self.localStore.getBlocks(addresses)

method getBlocks*(
    self: NetworkStore, treeCid: Cid, indices: seq[Natural]
): Future[?!seq[Block]] {.async: (raw: true, raises: [CancelledError]).} =
  ## Get multiple blocks by tree CID - delegates to localStore
  self.localStore.getBlocks(treeCid, indices)

method delBlocks*(
    self: NetworkStore, addresses: seq[BlockAddress]
): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
  ## Delete multiple blocks - delegates to localStore
  self.localStore.delBlocks(addresses)

method delBlocks*(
    self: NetworkStore, treeCid: Cid, indices: seq[Natural]
): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
  ## Delete multiple blocks by tree CID - delegates to localStore
  self.localStore.delBlocks(treeCid, indices)

method getBlockRange*(
    self: NetworkStore, treeCid: Cid, start: Natural, count: Natural
): Future[?!seq[Block]] {.async: (raw: true, raises: [CancelledError]).} =
  ## Get a range of blocks - delegates to localStore
  self.localStore.getBlockRange(treeCid, start, count)

method getBlockAndProof*(
    self: NetworkStore, address: BlockAddress
): Future[?!(Block, ArchivistProof)] {.async: (raw: true, raises: [CancelledError]).} =
  ## Get block and proof by address - delegates to localStore
  self.localStore.getBlockAndProof(address)

method getBlocksAndProofs*(
    self: NetworkStore, addresses: seq[BlockAddress]
): Future[?!seq[(Block, ArchivistProof)]] {.
    async: (raw: true, raises: [CancelledError])
.} =
  ## Get multiple blocks and proofs - delegates to localStore
  self.localStore.getBlocksAndProofs(addresses)

method getBlocksAndProofs*(
    self: NetworkStore, treeCid: Cid, indices: seq[Natural]
): Future[?!seq[(Block, ArchivistProof)]] {.
    async: (raw: true, raises: [CancelledError])
.} =
  ## Get multiple blocks and proofs by tree CID - delegates to localStore
  self.localStore.getBlocksAndProofs(treeCid, indices)

method putCidsAndProofs*(
    self: NetworkStore, treeCid: Cid, items: seq[(Natural, Cid, ArchivistProof)]
): Future[?!void] {.async: (raw: true, raises: [CancelledError]).} =
  ## Put multiple CIDs and proofs - delegates to localStore
  self.localStore.putCidsAndProofs(treeCid, items)

method getCidsAndProofs*(
    self: NetworkStore, treeCid: Cid, indices: seq[Natural]
): Future[?!seq[(Cid, ArchivistProof)]] {.async: (raw: true, raises: [CancelledError]).} =
  ## Get multiple CIDs and proofs - delegates to localStore
  self.localStore.getCidsAndProofs(treeCid, indices)

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
