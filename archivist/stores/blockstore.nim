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
import pkg/questionable
import pkg/questionable/results

import ../blocktype
import ../merkletree
import ../utils
import ../manifest

export blocktype

type
  BlockNotFoundError* = object of ArchivistError

  BlockType* {.pure.} = enum
    Manifest
    Block
    Both

  CidCallback* = proc(cid: Cid): Future[void] {.gcsafe, async: (raises: []).}
  BlockStore* = ref object of RootObj
    onBlockStored*: ?CidCallback

###########################################################
# Get methods
###########################################################

method getBlocks*(
    self: BlockStore, cids: seq[Cid]
): Future[?!seq[Block]] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Get multiple blocks by CID as a batch (no tree context).
  ## Missing blocks are silently omitted from the result.
  ##

  raiseAssert("getBlocks by cids not implemented!")

method getBlock*(
    self: BlockStore, cid: Cid
): Future[?!Block] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Get a block from the blockstore by CID (no tree context).
  ## Default: delegates to getBlocks batch.
  ##

  let blocks = ?await self.getBlocks(@[cid])
  if blocks.len == 0:
    return failure(newException(BlockNotFoundError, "Block not found"))
  success(blocks[0])

method getBlocks*(
    self: BlockStore, treeCid: Cid, indices: seq[Natural]
): Future[?!seq[(Natural, Block)]] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Get multiple blocks by tree CID and indices as a batch
  ##

  raiseAssert("getBlocks by treeCid not implemented!")

method getBlock*(
    self: BlockStore, treeCid: Cid, index: Natural
): Future[?!Block] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Get a block by tree CID and index.
  ## Default: delegates to getBlocks batch.
  ##

  let blocks = ?await self.getBlocks(treeCid, @[index])
  if blocks.len == 0:
    return failure(newException(BlockNotFoundError, "Block not found"))
  success(blocks[0][1])

method getBlocksAndProofs*(
    self: BlockStore, treeCid: Cid, indices: seq[Natural]
): Future[?!seq[(Natural, Block, ?ArchivistProof)]] {.
    base, async: (raises: [CancelledError]), gcsafe
.} =
  ## Get multiple blocks and proofs by tree CID and indices as a batch
  ##

  raiseAssert("getBlocksAndProofs by treeCid not implemented!")

method getBlockAndProof*(
    self: BlockStore, treeCid: Cid, index: Natural
): Future[?!(Natural, Block, ?ArchivistProof)] {.
    base, async: (raises: [CancelledError]), gcsafe
.} =
  ## Get a block and proof by tree CID and index.
  ## Default: delegates to getBlocksAndProofs batch.
  ##

  let results = ?await self.getBlocksAndProofs(treeCid, @[index])
  if results.len == 0:
    return failure(newException(BlockNotFoundError, "Block not found"))
  success(results[0])

method getCidsAndProofs*(
    self: BlockStore, treeCid: Cid, indices: seq[Natural]
): Future[?!seq[(Cid, ?ArchivistProof)]] {.
    base, async: (raises: [CancelledError]), gcsafe
.} =
  ## Get multiple CIDs and proofs as a batch
  ##

  raiseAssert("getCidsAndProofs not implemented!")

method getCidAndProof*(
    self: BlockStore, treeCid: Cid, index: Natural
): Future[?!(Cid, ?ArchivistProof)] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Get a CID and proof by tree CID and index.
  ## Default: delegates to getCidsAndProofs batch.
  ##

  let results = ?await self.getCidsAndProofs(treeCid, @[index])
  if results.len == 0:
    return failure(newException(BlockNotFoundError, "CID and proof not found"))
  success(results[0])

method getCid*(
    self: BlockStore, treeCid: Cid, index: Natural
): Future[?!Cid] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Get a cid given a tree and index
  ##

  raiseAssert("getCid by treecid not implemented!")

method completeBlocks*(
    self: BlockStore, treeCid: Cid, blocks: seq[(Natural, Block)]
): Future[void] {.base, async: (raises: [CancelledError]), gcsafe.} =
  discard

method completeBlock*(
    self: BlockStore, treeCid: Cid, index: Natural, blk: Block
): Future[void] {.base, async: (raises: [CancelledError]), gcsafe.} =
  await self.completeBlocks(treeCid, @[(index, blk)])

###########################################################
# Put methods
###########################################################

method putBlock*(
    self: BlockStore, blk: Block, ttl = Duration.none
): Future[?!void] {.
    base,
    gcsafe,
    async: (raises: [CancelledError]),
    deprecated: "Use putBlocks(treeCid, seq[(Block, Natural, ?ArchivistProof)])"
.} =
  ## Put a block to the blockstore (deprecated)
  ##

  raiseAssert("putBlock not implemented!")

method putBlocks*(
    self: BlockStore, treeCid: Cid, items: seq[(Block, Natural, ?ArchivistProof)]
): Future[?!void] {.base, async: (raises: [CancelledError]).} =
  ## Put multiple leafs and blocks as a batch (primary method)
  ##

  raiseAssert("putBlocks not implemented!")

method putBlock*(
    self: BlockStore, treeCid: Cid, blk: Block, index: Natural, proof: ?ArchivistProof
): Future[?!void] {.base, async: (raises: [CancelledError]).} =
  ## Put a single leaf and block.
  ## Default: delegates to putBlocks batch.
  ##

  await self.putBlocks(treeCid, @[(blk, index, proof)])

method putBlocks*(
    self: BlockStore, treeCid: Cid, blocks: seq[(Natural, Block)]
): Future[?!void] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Put multiple blocks without proofs as a batch
  ##

  raiseAssert("putBlocks not implemented!")

method putBlock*(
    self: BlockStore, treeCid: Cid, blk: Block, index: Natural
): Future[?!void] {.base, async: (raises: [CancelledError]).} =
  ## Put a single block without proof.
  ## Default: delegates to putBlocks(treeCid, seq[(Natural, Block)]) batch.
  ##

  await self.putBlocks(treeCid, @[(index, blk)])

method putCidsAndProofs*(
    self: BlockStore, treeCid: Cid, items: seq[(Natural, Cid, ArchivistProof)]
): Future[?!void] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Put multiple CIDs and proofs as a batch
  ##

  raiseAssert("putCidsAndProofs not implemented!")

method putCidAndProof*(
    self: BlockStore, treeCid: Cid, index: Natural, blockCid: Cid, proof: ArchivistProof
): Future[?!void] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Put a CID and proof.
  ## Default: delegates to putCidsAndProofs batch.
  ##

  await self.putCidsAndProofs(treeCid, @[(index, blockCid, proof)])

method putCellCidsAndProofs*(
    self: BlockStore, treeCid: Cid, items: seq[(Natural, Cid, Cid, ArchivistProof)]
): Future[?!void] {.base, async: (raises: [CancelledError]).} =
  ## Put multiple cell CIDs and proofs as a batch
  ##

  raiseAssert("putCellCidsAndProofs not implemented!")

method putCellCidAndProof*(
    self: BlockStore,
    treeCid: Cid,
    cellCid: Cid,
    blkCid: Cid,
    index: Natural,
    proof: ArchivistProof,
): Future[?!void] {.base, async: (raises: [CancelledError]).} =
  ## Put a single cell CID and proof.
  ## Default: delegates to putCellCidsAndProofs batch.
  ##

  await self.putCellCidsAndProofs(treeCid, @[(index, cellCid, blkCid, proof)])

###########################################################
# Delete methods
###########################################################

method delBlock*(
    self: BlockStore, cid: Cid
): Future[?!void] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Delete a block from the blockstore by CID
  ##

  raiseAssert("delBlock not implemented!")

method delBlocks*(
    self: BlockStore, treeCid: Cid, indices: seq[Natural]
): Future[?!void] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Delete multiple blocks by tree CID and indices as a batch
  ##

  raiseAssert("delBlocks by treeCid not implemented!")

method delBlock*(
    self: BlockStore, treeCid: Cid, index: Natural
): Future[?!void] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Delete a block by tree CID and index.
  ## Default: delegates to delBlocks batch.
  ##

  await self.delBlocks(treeCid, @[index])

###########################################################
# Has methods
###########################################################

method hasBlock*(
    self: BlockStore, cid: Cid
): Future[?!bool] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Check if the block exists in the blockstore
  ##

  raiseAssert("hasBlock not implemented!")

method hasBlocks*(
    self: BlockStore, tree: Cid, indices: seq[Natural]
): Future[?!seq[(Natural, bool)]] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Check if multiple blocks exist in the blockstore
  ##

  raiseAssert("hasBlocks not implemented!")

method hasBlock*(
    self: BlockStore, tree: Cid, index: Natural
): Future[?!bool] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Check if block exists by tree CID and index.
  ## Default: delegates to hasBlocks batch.
  ##

  let results = ?await self.hasBlocks(tree, @[index])
  if results.len == 0:
    return success(false)
  success(results[0][1])

###########################################################
# Lifecycle / special methods
###########################################################

method storeManifest*(
    self: BlockStore, manifest: Manifest
): Future[?!Block] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Store a manifest to the blockstore and return the manifest block
  ##

  raiseAssert("storeManifest not implemented!")

method fetchManifest*(
    self: BlockStore, cid: Cid
): Future[?!Manifest] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Fetch a manifest from the blockstore by CID
  ##

  raiseAssert("fetchManifest not implemented!")

method listBlocks*(
    self: BlockStore, blockType = BlockType.Manifest
): Future[?!SafeAsyncIter[Cid]] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Get the list of blocks in the BlockStore. This is an intensive operation
  ##

  raiseAssert("listBlocks not implemented!")

method close*(self: BlockStore): Future[void] {.base, async: (raises: []), gcsafe.} =
  ## Close the blockstore, cleaning up resources managed by it.
  ## For some implementations this may be a no-op
  ##

  raiseAssert("close not implemented!")

###########################################################
# Convenience helpers
###########################################################

proc contains*(
    self: BlockStore, blk: Cid
): Future[bool] {.async: (raises: [CancelledError]), gcsafe.} =
  ## Check if the block exists in the blockstore.
  ## Return false if error encountered
  ##

  return (await self.hasBlock(blk)) |? false

proc contains*(
    self: BlockStore, treeCid: Cid, index: Natural
): Future[bool] {.async: (raises: [CancelledError]), gcsafe.} =
  return (await self.hasBlock(treeCid, index)) |? false
