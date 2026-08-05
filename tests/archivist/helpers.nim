import std/sequtils

import pkg/chronos
import pkg/libp2p
import pkg/libp2p/varint
import pkg/stew/bitseqs
import pkg/archivist/blocktype
import pkg/archivist/stores
import pkg/archivist/manifest
import pkg/archivist/merkletree
import pkg/archivist/blockexchange
import pkg/archivist/rng
import pkg/archivist/utils

import ./helpers/randomchunker
import ./helpers/mockchunker
import ./helpers/mockdiscovery
import ./helpers/always
import ../checktest

export randomchunker, mockdiscovery, mockchunker, always, checktest, manifest

export libp2p except setup, eventually

# NOTE: The meaning of equality for blocks
# is changed here, because blocks are now `ref`
# types. This is only in tests!!!
func `==`*(a, b: Block): bool =
  (a.cid == b.cid) and (a.data == b.data)

proc calcEcBlocksCount*(blocksCount: int, ecK, ecM: int): int =
  let
    rounded = roundUp(blocksCount, ecK)
    steps = divUp(rounded, ecK)

  rounded + (steps * ecM)

proc lenPrefix*(msg: openArray[byte]): seq[byte] =
  ## Write `msg` with a varint-encoded length prefix
  ##

  let vbytes = PB.toBytes(msg.len().uint64)
  var buf = newSeqUninitialized[byte](msg.len() + vbytes.len)
  buf[0 ..< vbytes.len] = vbytes.toOpenArray()
  buf[vbytes.len ..< buf.len] = msg

  return buf

proc makeManifestAndTree*(blocks: seq[Block]): ?!(Manifest, ArchivistTree) =
  if blocks.len == 0:
    return failure("Blocks list was empty")

  let
    datasetSize = blocks.mapIt(it.data.len).foldl(a + b)
    blockSize = blocks.mapIt(it.data.len).foldl(max(a, b))
    tree = ?ArchivistTree.init(blocks.mapIt(it.cid))
    treeCid = ?tree.rootCid
    manifest = Manifest.new(
      treeCid = treeCid,
      blockSize = NBytes(blockSize),
      datasetSize = NBytes(datasetSize),
    )

  return success((manifest, tree))

proc makeWantList*(
    cids: seq[Cid],
    priority: int = 0,
    cancel: bool = false,
    wantType: WantType = WantType.WantHave,
    full: bool = false,
    sendDontHave: bool = false,
): WantList =
  WantList(
    entries: cids.mapIt(
      WantListEntry(
        address: BlockAddress(leaf: false, cid: it),
        priority: priority.int32,
        cancel: cancel,
        wantType: wantType,
        sendDontHave: sendDontHave,
      )
    ),
    full: full,
  )

proc storeDataGetManifest*(
    store: RepoStore, blocks: seq[Block]
): Future[?!Manifest] {.async: (raises: [CancelledError]).} =
  let tmpTreeCid = ?await store.createTmpOverlay()

  for i, blk in blocks:
    ?await store.putBlock(tmpTreeCid, blk, i)

  let
    (manifest, tree) = ?makeManifestAndTree(blocks)
    treeCid = ?tree.rootCid

  ?await store.finalizeOverlay(tmpTreeCid, treeCid)

  for i in 0 ..< tree.leavesCount:
    let proof = ?tree.getProof(i)
    ?await store.putCidAndProof(treeCid, i, blocks[i].cid, proof)

  success manifest

proc storeDataGetManifest*(
    store: RepoStore, chunker: Chunker
): Future[?!Manifest] {.async: (raises: [CancelledError]).} =
  var blocks = newSeq[Block]()

  while (let chunk = ?await chunker.getBytes(); chunk.len > 0):
    blocks.add(?Block.new(chunk))

  await storeDataGetManifest(store, blocks)

proc makeRandomBlocks*(
    datasetSize: int, blockSize: NBytes
): Future[?!seq[Block]] {.async.} =
  var
    chunker =
      RandomChunker.new(Rng.instance(), size = datasetSize, chunkSize = blockSize)
    blocks: seq[Block]

  while true:
    let chunk = ?await chunker.getBytes()
    if chunk.len <= 0:
      break

    blocks.add(Block.new(chunk).tryGet())

  success blocks

proc corruptBlocks*(
    store: BlockStore, manifest: Manifest, blks, bytes: int
): Future[seq[int]] {.async.} =
  var pos: seq[int]

  doAssert blks < manifest.blocksCount
  while pos.len < blks:
    let i = Rng.instance.rand(manifest.blocksCount - 1)
    if pos.find(i) >= 0:
      continue

    pos.add(i)
    var
      blk = (await store.getBlock(manifest.treeCid, i)).tryGet()
      bytePos: seq[int]

    doAssert bytes < blk.data.len
    while bytePos.len <= bytes:
      let ii = Rng.instance.rand(blk.data.len - 1)
      if bytePos.find(ii) >= 0:
        continue

      bytePos.add(ii)
      blk.data[ii] = byte 0
  return pos

proc makeBitSeq*(len: int, setBits: seq[int] = @[]): BitSeq =
  ## Create a BitSeq with specified bits set.
  ## If setBits is empty, all bits are set.
  ##
  var bits = BitSeq.init(len)
  if setBits.len == 0:
    for i in 0 ..< len:
      bits.setBit(i)
  else:
    for i in setBits:
      if i < len:
        bits.setBit(i)
  bits

proc storeBlocksWithOverlay*(
    store: RepoStore,
    treeCid: Cid,
    blocks: seq[Block],
    tree: ArchivistTree,
    indices: seq[int] = @[],
    status: ?OverlayStatus = OverlayStatus.Completed.some,
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Store blocks with overlay context.
  ## Creates overlay, stores blocks with proofs.
  ## If indices is empty, all blocks are stored.
  ##
  let
    idx =
      if indices.len == 0:
        toSeq(0 ..< blocks.len)
      else:
        indices
    bits = makeBitSeq(blocks.len, idx)

  ?await store.putOverlay(treeCid, status, bits)

  var items: seq[(Block, Natural, ?ArchivistProof)]
  for i in idx:
    let proof = ?tree.getProof(i)
    items.add((blocks[i], i.Natural, proof.some))

  ?await store.putBlocks(treeCid, items)

  success()

proc storeBlocksWithOverlay*(
    store: RepoStore,
    treeCid: Cid,
    blocks: seq[Block],
    tree: ArchivistTree,
    indices: openArray[int],
    status: ?OverlayStatus = OverlayStatus.Completed.some,
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Store blocks with overlay context (openArray variant).
  ##
  await storeBlocksWithOverlay(store, treeCid, blocks, tree, @indices, status)
