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

import ../clock
import ../blocktype
import ../merkletree
import ../utils

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

method getBlock*(
    self: BlockStore, cid: Cid
): Future[?!Block] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Get a block from the blockstore
  ##

  raiseAssert("getBlock by cid not implemented!")

method getBlock*(
    self: BlockStore, treeCid: Cid, index: Natural
): Future[?!Block] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Get a block from the blockstore
  ##

  raiseAssert("getBlock by treecid not implemented!")

method getCid*(
    self: BlockStore, treeCid: Cid, index: Natural
): Future[?!Cid] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Get a cid given a tree and index
  ##

  raiseAssert("getCid by treecid not implemented!")

method getBlock*(
    self: BlockStore, address: BlockAddress
): Future[?!Block] {.base, async: (raw: true, raises: [CancelledError]), gcsafe.} =
  ## Get a block from the blockstore — routes to leaf or cid variant
  ##

  if address.leaf:
    self.getBlock(address.treeCid, address.index)
  else:
    self.getBlock(address.cid)

method completeBlock*(
    self: BlockStore, address: BlockAddress, blk: Block
) {.base, gcsafe.} =
  discard

method getBlockAndProof*(
    self: BlockStore, treeCid: Cid, index: Natural
): Future[?!(Block, ArchivistProof)] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Get a block and associated inclusion proof by Cid of a merkle tree and an index of a leaf in a tree
  ##

  raiseAssert("getBlockAndProof not implemented!")

method putBlock*(
    self: BlockStore, blk: Block, ttl = Duration.none
): Future[?!void] {.
    base, async: (raises: [CancelledError]), gcsafe, deprecated: "Use putLeafAndBlock"
.} =
  ## Put a block to the blockstore
  ##

  raiseAssert("putBlock not implemented!")

method putLeafsAndBlocks*(
    self: BlockStore, treeCid: Cid, items: seq[(Block, Natural, ArchivistProof)]
): Future[?!void] {.base, async: (raises: [CancelledError]).} =
  ## Put multiple leafs and blocks as a batch (primary method)
  ##

  raiseAssert("putLeafsAndBlocks not implemented!")

method putLeafAndBlock*(
    self: BlockStore, treeCid: Cid, blk: Block, index: Natural, proof: ArchivistProof
): Future[?!void] {.base, async: (raises: [CancelledError]).} =
  ## Puts a leaf and block, for temporal leafs
  ## treeCid is a unique temporary hash and proof
  ## is nil (or none when changed to optional)
  ##
  ## NOTE: Wrapper for putLeafsAndBlocks - implements single-item logic
  ## by calling batch with @[item]

  await self.putLeafsAndBlocks(treeCid, @[(blk, index, proof)])

method putCidAndProof*(
    self: BlockStore, treeCid: Cid, index: Natural, blockCid: Cid, proof: ArchivistProof
): Future[?!void] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Put a block proof to the blockstore
  ##

  raiseAssert("putCidAndProof not implemented!")

method getCidAndProof*(
    self: BlockStore, treeCid: Cid, index: Natural
): Future[?!(Cid, ArchivistProof)] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Get a block CID and proof from the blockstore
  ##

  raiseAssert("getCidAndProof not implemented!")

method delBlock*(
    self: BlockStore, cid: Cid
): Future[?!void] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Delete a block from the blockstore
  ##

  raiseAssert("delBlock not implemented!")

method delBlock*(
    self: BlockStore, treeCid: Cid, index: Natural
): Future[?!void] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Delete a block from the blockstore
  ##

  raiseAssert("delBlock not implemented!")

method putBlocks*(
    self: BlockStore, blocks: seq[Block]
): Future[?!void] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Put multiple blocks to the blockstore as a batch
  ##

  raiseAssert("putBlocks not implemented!")

method getBlocks*(
    self: BlockStore, addresses: seq[BlockAddress]
): Future[?!seq[Block]] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Get multiple blocks from the blockstore as a batch
  ##

  raiseAssert("getBlocks by addresses not implemented!")

method getBlocks*(
    self: BlockStore, treeCid: Cid, indices: seq[Natural]
): Future[?!seq[Block]] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Get multiple blocks by tree CID and indices as a batch
  ##

  raiseAssert("getBlocks by treeCid not implemented!")

method delBlocks*(
    self: BlockStore, addresses: seq[BlockAddress]
): Future[?!void] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Delete multiple blocks from the blockstore as a batch
  ##

  raiseAssert("delBlocks by addresses not implemented!")

method delBlocks*(
    self: BlockStore, treeCid: Cid, indices: seq[Natural]
): Future[?!void] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Delete multiple blocks by tree CID and indices as a batch
  ##

  raiseAssert("delBlocks by treeCid not implemented!")

method getBlockRange*(
    self: BlockStore, treeCid: Cid, start: Natural, count: Natural
): Future[?!seq[Block]] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Get a contiguous range of blocks from the blockstore as a batch
  ##

  raiseAssert("getBlockRange not implemented!")

method getBlockAndProof*(
    self: BlockStore, address: BlockAddress
): Future[?!(Block, ArchivistProof)] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Get a block and proof by BlockAddress — requires leaf address
  ##

  if not address.leaf:
    return
      failure(newException(ArchivistError, "getBlockAndProof requires a leaf address"))

  await self.getBlockAndProof(address.treeCid, address.index)

method getBlocksAndProofs*(
    self: BlockStore, addresses: seq[BlockAddress]
): Future[?!seq[(Block, ArchivistProof)]] {.
    base, async: (raises: [CancelledError]), gcsafe
.} =
  ## Get multiple blocks and proofs as a batch
  ##

  raiseAssert("getBlocksAndProofs by addresses not implemented!")

method getBlocksAndProofs*(
    self: BlockStore, treeCid: Cid, indices: seq[Natural]
): Future[?!seq[(Block, ArchivistProof)]] {.
    base, async: (raises: [CancelledError]), gcsafe
.} =
  ## Get multiple blocks and proofs by tree CID and indices as a batch
  ##

  raiseAssert("getBlocksAndProofs by treeCid not implemented!")

method putCidsAndProofs*(
    self: BlockStore, treeCid: Cid, items: seq[(Natural, Cid, ArchivistProof)]
): Future[?!void] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Put multiple CIDs and proofs as a batch
  ##

  raiseAssert("putCidsAndProofs not implemented!")

method getCidsAndProofs*(
    self: BlockStore, treeCid: Cid, indices: seq[Natural]
): Future[?!seq[(Cid, ArchivistProof)]] {.
    base, async: (raises: [CancelledError]), gcsafe
.} =
  ## Get multiple CIDs and proofs as a batch
  ##

  raiseAssert("getCidsAndProofs not implemented!")

method hasBlock*(
    self: BlockStore, cid: Cid
): Future[?!bool] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Check if the block exists in the blockstore
  ##

  raiseAssert("hasBlock not implemented!")

method hasBlock*(
    self: BlockStore, tree: Cid, index: Natural
): Future[?!bool] {.base, async: (raises: [CancelledError]), gcsafe.} =
  ## Check if the block exists in the blockstore
  ##

  raiseAssert("hasBlock not implemented!")

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

proc contains*(
    self: BlockStore, blk: Cid
): Future[bool] {.async: (raises: [CancelledError]), gcsafe.} =
  ## Check if the block exists in the blockstore.
  ## Return false if error encountered
  ##

  return (await self.hasBlock(blk)) |? false

proc contains*(
    self: BlockStore, address: BlockAddress
): Future[bool] {.async: (raises: [CancelledError]), gcsafe.} =
  return
    if address.leaf:
      (await self.hasBlock(address.treeCid, address.index)) |? false
    else:
      (await self.hasBlock(address.cid)) |? false
