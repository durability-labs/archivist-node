## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/math
import std/sequtils
import std/sugar

import pkg/libp2p
import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/constantine/math/io/io_fields

import ../../logutils
import ../../utils
import ../../utils/poseidon2digest
import ../../stores
import ../../manifest
import ../../merkletree
import ../../utils/asynciter
import ../../indexingstrategy

import ../converters

export converters, asynciter

logScope:
  topics = "archivist slotsbuilder"

type SlotsBuilder*[SomeTree, SomeHash] = ref object of RootObj
  networkStore: BlockStore
  repoStore: RepoStore
  manifest: Manifest # current manifest
  strategy: IndexingStrategy # indexing strategy
  cellSize: NBytes # cell size
  numSlotBlocks: Natural
    # number of blocks per slot (should yield a power of two number of cells)
  slotRoots: seq[SomeHash] # roots of the slots
  emptyBlock: seq[byte] # empty block
  verifiableTree: ?SomeTree # verification tree (dataset tree)
  emptyDigestTree: SomeTree # empty digest tree for empty blocks

func verifiable*[SomeTree, SomeHash](
    self: SlotsBuilder[SomeTree, SomeHash]
): bool {.inline.} =
  ## Returns true if the slots are verifiable.
  ##

  self.manifest.verifiable

func slotRoots*[SomeTree, SomeHash](
    self: SlotsBuilder[SomeTree, SomeHash]
): seq[SomeHash] {.inline.} =
  ## Returns the slot roots.
  ##

  self.slotRoots

func verifyTree*[SomeTree, SomeHash](
    self: SlotsBuilder[SomeTree, SomeHash]
): ?SomeTree {.inline.} =
  ## Returns the slots tree (verification tree).
  ##

  self.verifiableTree

func verifyRoot*[SomeTree, SomeHash](
    self: SlotsBuilder[SomeTree, SomeHash]
): ?SomeHash {.inline.} =
  ## Returns the slots root (verification root).
  ##

  if tree =? self.verifyTree and root =? tree.root:
    return some root

func numSlots*[SomeTree, SomeHash](self: SlotsBuilder[SomeTree, SomeHash]): Natural =
  ## Number of slots.
  ##

  self.manifest.numSlots

func numSlotBlocks*[SomeTree, SomeHash](
    self: SlotsBuilder[SomeTree, SomeHash]
): Natural =
  ## Number of blocks per slot.
  ##

  self.numSlotBlocks

func numBlocks*[SomeTree, SomeHash](self: SlotsBuilder[SomeTree, SomeHash]): Natural =
  ## Number of blocks.
  ##

  self.numSlotBlocks * self.manifest.numSlots

func numBlockCells*[SomeTree, SomeHash](
    self: SlotsBuilder[SomeTree, SomeHash]
): Natural =
  ## Number of cells per block.
  ##

  (self.manifest.blockSize div self.cellSize).Natural

func cellSize*[SomeTree, SomeHash](self: SlotsBuilder[SomeTree, SomeHash]): NBytes =
  ## Cell size.
  ##

  self.cellSize

func numSlotCells*[SomeTree, SomeHash](
    self: SlotsBuilder[SomeTree, SomeHash]
): Natural =
  ## Number of cells per slot.
  ##

  self.numBlockCells * self.numSlotBlocks

func slotIndicesIter*[SomeTree, SomeHash](
    self: SlotsBuilder[SomeTree, SomeHash], slot: Natural
): ?!Iter[int] =
  ## Returns the slot indices.
  ##

  self.strategy.getIndices(slot).catch

func slotIndices*[SomeTree, SomeHash](
    self: SlotsBuilder[SomeTree, SomeHash], slot: Natural
): ?!seq[int] =
  ## Returns the slot indices.
  ##

  success toSeq(?catch(self.strategy.getIndices(slot)))

func manifest*[SomeTree, SomeHash](self: SlotsBuilder[SomeTree, SomeHash]): Manifest =
  ## Returns the manifest.
  ##

  self.manifest

proc buildBlockTree*[SomeTree, SomeHash](
    self: SlotsBuilder[SomeTree, SomeHash], blkIdx: Natural, slotPos: Natural
): Future[?!(seq[byte], SomeTree)] {.async: (raises: [CancelledError]).} =
  ## Build the block digest tree and return a tuple with the
  ## block data and the tree.
  ##

  logScope:
    blkIdx = blkIdx
    slotPos = slotPos
    numSlotBlocks = self.manifest.numSlotBlocks
    cellSize = self.cellSize

  trace "Building block tree"
  if slotPos > (self.manifest.numSlotBlocks - 1):
    # pad blocks are 0 byte blocks
    trace "Returning empty digest tree for pad block"
    return success (self.emptyBlock, self.emptyDigestTree)

  let blk = ?await self.networkStore.getBlock(self.manifest.treeCid, blkIdx)
  if blk.isEmpty:
    return success (self.emptyBlock, self.emptyDigestTree)

  let tree = ?SomeTree.digestTree(blk.data, self.cellSize.int)
  success (blk.data, tree)

proc getCellHashes*[SomeTree, SomeHash](
    self: SlotsBuilder[SomeTree, SomeHash], slotIndex: Natural
): Future[?!seq[SomeHash]] {.async: (raises: [CancelledError]).} =
  ## Collect all the cells from a block and return
  ## their hashes.
  ##

  let
    treeCid = self.manifest.treeCid
    blockCount = self.manifest.blocksCount
    numberOfSlots = self.manifest.numSlots

  logScope:
    treeCid = treeCid
    origBlockCount = blockCount
    numberOfSlots = numberOfSlots
    slotIndex = slotIndex

  let hashes = collect(newSeq):
    for i, blkIdx in ?catch(self.strategy.getIndices(slotIndex)):
      logScope:
        blkIdx = blkIdx
        pos = i

      trace "Getting block CID for tree at index"
      let
        (_, tree) = ?await self.buildBlockTree(blkIdx, i)
        digest = ?tree.root

      trace "Get block digest", digest = digest.toHex
      digest

  success hashes

proc buildSlotTree*[SomeTree, SomeHash](
    self: SlotsBuilder[SomeTree, SomeHash], slotIndex: Natural
): Future[?!SomeTree] {.async: (raises: [CancelledError]).} =
  ## Build the slot tree from the block digest hashes
  ## and return the tree.

  SomeTree.init(?await self.getCellHashes(slotIndex))

proc buildSlot*[SomeTree, SomeHash](
    self: SlotsBuilder[SomeTree, SomeHash], slotIndex: Natural
): Future[?!SomeHash] {.async: (raises: [CancelledError]).} =
  ## Build a slot tree and store the proofs in
  ## the block store.
  ##

  logScope:
    cid = self.manifest.treeCid
    slotIndex = slotIndex

  trace "Building slot tree"

  without tree =? (await self.buildSlotTree(slotIndex)) and
    treeCid =? tree.root .? toSlotCid, e:
    error "Failed to build slot tree", e = e.msg
    return failure(e)

  trace "Storing slot tree", treeCid, slotIndex, leaves = tree.leavesCount
  ?await withOverlay(
    self.repoStore,
    treeCid,
    status = Storing.some,
    body = proc(): Future[?!void] {.closure, async: (raises: [CancelledError]).} =
      for i, leaf in tree.leaves:
        without cellCid =? leaf.toCellCid, e:
          error "Failed to get CID for slot cell", e = e.msg
          return failure(e)

        without proof =? tree.getProof(i) and encodableProof =? proof.toEncodableProof,
          e:
          error "Failed to get proof for slot tree", e = e.msg
          return failure(e)

        ?await self.repoStore.putCidAndProof(treeCid, i, cellCid, encodableProof)
      success(),
  )

  tree.root()

func buildVerifyTree*[SomeTree, SomeHash](
    self: SlotsBuilder[SomeTree, SomeHash], slotRoots: openArray[SomeHash]
): ?!SomeTree =
  SomeTree.init(@slotRoots)

proc buildSlots*[SomeTree, SomeHash](
    self: SlotsBuilder[SomeTree, SomeHash]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Build all slot trees and store them in the block store.
  ##

  logScope:
    cid = self.manifest.treeCid
    blockCount = self.manifest.blocksCount

  trace "Building slots"

  if self.slotRoots.len == 0:
    self.slotRoots = collect(newSeq):
      for i in 0 ..< self.manifest.numSlots:
        ?await self.buildSlot(i)

  without tree =? self.buildVerifyTree(self.slotRoots) and root =? tree.root, e:
    error "Failed to build slot roots tree", e = e.msg
    return failure(e)

  if verifyTree =? self.verifyTree and verifyRoot =? verifyTree.root:
    if not bool(verifyRoot == root): # TODO: `!=` doesn't work for SecretBool
      return failure "Existing slots root doesn't match reconstructed root."

  self.verifiableTree = some tree

  success()

proc buildManifest*[SomeTree, SomeHash](
    self: SlotsBuilder[SomeTree, SomeHash]
): Future[?!Manifest] {.async: (raises: [CancelledError]).} =
  ## Build the manifest with the slot roots and return it.
  ##

  ?await self.buildSlots() # build the slots
  let rootCids = ?self.slotRoots.toSlotCids()
  without rootProvingCidRes =? self.verifyRoot .? toVerifyCid() and
    rootProvingCid =? rootProvingCidRes, e:
    error "Failed to map slot roots to CIDs", e = e.msg
    return failure(e)

  Manifest.new(
    self.manifest, rootProvingCid, rootCids, self.cellSize, self.strategy.strategyType
  )

proc new*[SomeTree, SomeHash](
    _: type SlotsBuilder[SomeTree, SomeHash],
    networkStore: BlockStore,
    repoStore: RepoStore,
    manifest: Manifest,
    strategy = LinearStrategy,
    cellSize = DefaultCellSize,
): ?!SlotsBuilder[SomeTree, SomeHash] =
  if not manifest.protected:
    trace "Manifest is not protected."
    return failure("Manifest is not protected.")

  logScope:
    blockSize = manifest.blockSize
    strategy = strategy
    cellSize = cellSize

  if (manifest.blocksCount mod manifest.numSlots) != 0:
    const msg = "Number of blocks must be divisible by number of slots."
    trace msg
    return failure(msg)

  let cellSize = if manifest.verifiable: manifest.cellSize else: cellSize
  if (manifest.blockSize mod cellSize) != 0.NBytes:
    const msg = "Block size must be divisible by cell size."
    trace msg
    return failure(msg)

  let
    numSlotBlocks = manifest.numSlotBlocks
    numBlockCells = (manifest.blockSize div cellSize).int # number of cells per block
    numSlotCells = manifest.numSlotBlocks * numBlockCells
      # number of uncorrected slot cells
    pow2SlotCells = nextPowerOfTwo(numSlotCells) # pow2 cells per slot
    numPadSlotBlocks = (pow2SlotCells div numBlockCells) - numSlotBlocks
      # pow2 blocks per slot

    numSlotBlocksTotal =
      # pad blocks per slot
      if numPadSlotBlocks > 0:
        numPadSlotBlocks + numSlotBlocks
      else:
        numSlotBlocks

    numBlocksTotal = numSlotBlocksTotal * manifest.numSlots # number of blocks per slot

    emptyBlock = newSeq[byte](manifest.blockSize.int)
    emptyDigestTree = ?SomeTree.digestTree(emptyBlock, cellSize.int)

    strategy =
      ?strategy.init(
        0,
        manifest.blocksCount - 1,
        manifest.numSlots,
        manifest.numSlots,
        numPadSlotBlocks,
      ).catch

  logScope:
    numSlotBlocks = numSlotBlocks
    numBlockCells = numBlockCells
    numSlotCells = numSlotCells
    pow2SlotCells = pow2SlotCells
    numPadSlotBlocks = numPadSlotBlocks
    numBlocksTotal = numBlocksTotal
    numSlotBlocksTotal = numSlotBlocksTotal
    strategy = strategy.strategyType

  trace "Creating slots builder"

  var self = SlotsBuilder[SomeTree, SomeHash](
    networkStore: networkStore,
    repoStore: repoStore,
    manifest: manifest,
    strategy: strategy,
    cellSize: cellSize,
    emptyBlock: emptyBlock,
    numSlotBlocks: numSlotBlocksTotal,
    emptyDigestTree: emptyDigestTree,
  )

  if manifest.verifiable:
    if manifest.slotRoots.len == 0 or manifest.slotRoots.len != manifest.numSlots:
      return failure "Manifest is verifiable but slot roots are missing or invalid."

    let
      slotRoots = manifest.slotRoots.mapIt((?it.fromSlotCid()))
      tree = ?self.buildVerifyTree(slotRoots)
      expectedRoot = ?manifest.verifyRoot.fromVerifyCid()
      verifyRoot = ?tree.root

    if verifyRoot != expectedRoot:
      return failure "Existing slots root doesn't match reconstructed root."

    self.slotRoots = slotRoots
    self.verifiableTree = some tree

  success self
