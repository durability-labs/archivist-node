## Mock BlockStore for testing
## Simple in-memory implementation to replace CacheStore in tests

{.push raises: [].}

import std/tables
import std/sequtils

import pkg/chronos
import pkg/libp2p/[cid, multicodec]
import pkg/questionable
import pkg/questionable/results

import pkg/archivist/blocktype
import pkg/archivist/stores/blockstore
import pkg/archivist/merkletree
import pkg/archivist/logutils
import pkg/archivist/utils/safeasynciter

export blockstore

logScope:
  topics = "archivist mockblockstore"

type MockBlockStore* = ref object of BlockStore
  blocks: Table[Cid, Block]
  cidAndProofs: Table[(Cid, Natural), (Cid, ArchivistProof)]

proc new*(T: type MockBlockStore, blocks: openArray[Block] = []): MockBlockStore =
  var store = MockBlockStore(
    blocks: initTable[Cid, Block](),
    cidAndProofs: initTable[(Cid, Natural), (Cid, ArchivistProof)](),
  )
  for blk in blocks:
    store.blocks[blk.cid] = blk
  store

method getBlock*(
    self: MockBlockStore, cid: Cid
): Future[?!Block] {.async: (raises: [CancelledError]).} =
  if cid.isEmpty:
    return cid.emptyBlock

  if blk =? self.blocks.getOrDefault(cid, Block()).some:
    if blk.cid == cid:
      return success(blk)

  return failure(newException(BlockNotFoundError, "Block not found: " & $cid))

method getBlock*(
    self: MockBlockStore, treeCid: Cid, index: Natural
): Future[?!Block] {.async: (raises: [CancelledError]).} =
  if pair =? self.cidAndProofs.getOrDefault((treeCid, index)).some:
    if pair[0] != Cid.default:
      return await self.getBlock(pair[0])

  return failure(newException(BlockNotFoundError, "Block not found"))

method getBlock*(
    self: MockBlockStore, address: BlockAddress
): Future[?!Block] {.async: (raw: true, raises: [CancelledError]).} =
  if address.leaf:
    self.getBlock(address.treeCid, address.index)
  else:
    self.getBlock(address.cid)

method putBlock*(
    self: MockBlockStore, blk: Block
): Future[?!void] {.async: (raises: [CancelledError]).} =
  if blk.cid notin self.blocks:
    self.blocks[blk.cid] = blk
    if onBlock =? self.onBlockStored:
      await onBlock(blk.cid)
  success()

method putCidAndProof*(
    self: MockBlockStore,
    treeCid: Cid,
    index: Natural,
    blockCid: Cid,
    proof: ArchivistProof,
): Future[?!void] {.async: (raises: [CancelledError]).} =
  self.cidAndProofs[(treeCid, index)] = (blockCid, proof)
  success()

method getCidAndProof*(
    self: MockBlockStore, treeCid: Cid, index: Natural
): Future[?!(Cid, ArchivistProof)] {.async: (raises: [CancelledError]).} =
  if pair =? self.cidAndProofs.getOrDefault((treeCid, index)).some:
    if pair[0] != Cid.default:
      return success(pair)

  return failure(newException(BlockNotFoundError, "CidAndProof not found"))

method getCid*(
    self: MockBlockStore, treeCid: Cid, index: Natural
): Future[?!Cid] {.async: (raises: [CancelledError]).} =
  without (cid, _) =? await self.getCidAndProof(treeCid, index), err:
    return failure(err)
  success(cid)

method getBlockAndProof*(
    self: MockBlockStore, treeCid: Cid, index: Natural
): Future[?!(Block, ArchivistProof)] {.async: (raises: [CancelledError]).} =
  without (cid, proof) =? await self.getCidAndProof(treeCid, index), err:
    return failure(err)
  without blk =? await self.getBlock(cid), err:
    return failure(err)
  success((blk, proof))

method delBlock*(
    self: MockBlockStore, cid: Cid
): Future[?!void] {.async: (raises: [CancelledError]).} =
  self.blocks.del(cid)
  success()

method delBlock*(
    self: MockBlockStore, treeCid: Cid, index: Natural
): Future[?!void] {.async: (raises: [CancelledError]).} =
  self.cidAndProofs.del((treeCid, index))
  success()

method hasBlock*(
    self: MockBlockStore, cid: Cid
): Future[?!bool] {.async: (raises: [CancelledError]).} =
  success(cid in self.blocks)

method hasBlock*(
    self: MockBlockStore, treeCid: Cid, index: Natural
): Future[?!bool] {.async: (raises: [CancelledError]).} =
  success((treeCid, index) in self.cidAndProofs)

method listBlocks*(
    self: MockBlockStore, blockType = BlockType.Manifest
): Future[?!SafeAsyncIter[Cid]] {.async: (raises: [CancelledError]).} =
  var cids: seq[Cid] = @[]
  for cid in self.blocks.keys:
    case blockType
    of BlockType.Manifest:
      if cid.mcodec == ManifestCodec:
        cids.add(cid)
    of BlockType.Block:
      if cid.mcodec == BlockCodec:
        cids.add(cid)
    of BlockType.Both:
      cids.add(cid)

  var idx = 0
  proc next(): Future[?!Cid] {.async: (raises: [CancelledError]).} =
    if idx < cids.len:
      let cid = cids[idx]
      inc idx
      return success(cid)
    return failure(newException(CatchableError, "No more items"))

  proc isFinished(): bool =
    idx >= cids.len

  success(SafeAsyncIter[Cid].new(next, isFinished))

method close*(self: MockBlockStore): Future[void] {.async: (raises: []).} =
  self.blocks.clear()
  self.cidAndProofs.clear()

# Batch operations - simple sequential implementation for tests
method putBlocks*(
    self: MockBlockStore, blocks: seq[Block]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  for blk in blocks:
    ?await self.putBlock(blk)
  success()

method getBlocks*(
    self: MockBlockStore, addresses: seq[BlockAddress]
): Future[?!seq[Block]] {.async: (raises: [CancelledError]).} =
  var results: seq[Block] = @[]
  for address in addresses:
    results.add(?await self.getBlock(address))
  success(results)

method getBlocks*(
    self: MockBlockStore, treeCid: Cid, indices: seq[Natural]
): Future[?!seq[Block]] {.async: (raises: [CancelledError]).} =
  var results: seq[Block] = @[]
  for index in indices:
    results.add(?await self.getBlock(treeCid, index))
  success(results)

method delBlocks*(
    self: MockBlockStore, addresses: seq[BlockAddress]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  for address in addresses:
    if address.leaf:
      ?await self.delBlock(address.treeCid, address.index)
    else:
      ?await self.delBlock(address.cid)
  success()

method delBlocks*(
    self: MockBlockStore, treeCid: Cid, indices: seq[Natural]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  for index in indices:
    ?await self.delBlock(treeCid, index)
  success()

method getBlockRange*(
    self: MockBlockStore, treeCid: Cid, start: Natural, count: Natural
): Future[?!seq[Block]] {.async: (raises: [CancelledError]).} =
  var indices: seq[Natural] = @[]
  for i in start ..< start + count:
    indices.add(i)
  await self.getBlocks(treeCid, indices)

method getBlockAndProof*(
    self: MockBlockStore, address: BlockAddress
): Future[?!(Block, ArchivistProof)] {.async: (raises: [CancelledError]).} =
  if not address.leaf:
    return failure(newException(BlockNotFoundError, "BlockAddress must be a leaf"))
  await self.getBlockAndProof(address.treeCid, address.index)

method getBlocksAndProofs*(
    self: MockBlockStore, addresses: seq[BlockAddress]
): Future[?!seq[(Block, ArchivistProof)]] {.async: (raises: [CancelledError]).} =
  var results: seq[(Block, ArchivistProof)] = @[]
  for address in addresses:
    results.add(?await self.getBlockAndProof(address))
  success(results)

method getBlocksAndProofs*(
    self: MockBlockStore, treeCid: Cid, indices: seq[Natural]
): Future[?!seq[(Block, ArchivistProof)]] {.async: (raises: [CancelledError]).} =
  var results: seq[(Block, ArchivistProof)] = @[]
  for index in indices:
    results.add(?await self.getBlockAndProof(treeCid, index))
  success(results)

method putCidsAndProofs*(
    self: MockBlockStore, treeCid: Cid, items: seq[(Natural, Cid, ArchivistProof)]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  for (index, blockCid, proof) in items:
    ?await self.putCidAndProof(treeCid, index, blockCid, proof)
  success()

method getCidsAndProofs*(
    self: MockBlockStore, treeCid: Cid, indices: seq[Natural]
): Future[?!seq[(Cid, ArchivistProof)]] {.async: (raises: [CancelledError]).} =
  var results: seq[(Cid, ArchivistProof)] = @[]
  for index in indices:
    results.add(?await self.getCidAndProof(treeCid, index))
  success(results)
