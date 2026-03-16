import std/sugar

import pkg/chronos
import pkg/libp2p/cid

import pkg/archivist/archivisttypes
import pkg/archivist/stores
import pkg/archivist/merkletree
import pkg/archivist/manifest
import pkg/archivist/blocktype as bt
import pkg/archivist/chunker
import pkg/archivist/indexingstrategy
import pkg/archivist/slots
import pkg/archivist/rng

import ../helpers

proc createBlocks*(chunker: Chunker): Future[seq[bt.Block]] {.async.} =
  collect(newSeq):
    while (let chunk = (await chunker.getBytes()).tryGet; chunk.len > 0):
      bt.Block.new(chunk).tryGet()

proc createProtectedManifest*(
    datasetBlocks: seq[bt.Block],
    store: RepoStore,
    numDatasetBlocks: int,
    ecK: int,
    ecM: int,
    blockSize: NBytes,
    originalDatasetSize: int,
    totalDatasetSize: int,
): Future[tuple[manifest: Manifest, protected: Manifest]] {.async.} =
  let
    cids = datasetBlocks.mapIt(it.cid)
    datasetTree = ArchivistTree.init(cids[0 ..< numDatasetBlocks]).tryGet()
    datasetTreeCid = datasetTree.rootCid().tryGet()
    protectedTree = ArchivistTree.init(cids).tryGet()
    protectedTreeCid = protectedTree.rootCid().tryGet()

  # Create overlay for dataset tree and store blocks + proofs
  let tmpDatasetCid = (await store.createTmpOverlay()).tryGet()
  for i, blk in datasetBlocks[0 ..< numDatasetBlocks]:
    (await store.putBlock(tmpDatasetCid, blk, i)).tryGet()
  (await store.finalizeOverlay(tmpDatasetCid, datasetTreeCid)).tryGet()
  for index in 0 ..< numDatasetBlocks:
    let proof = datasetTree.getProof(index).tryGet()
    (await store.putCidAndProof(datasetTreeCid, index, cids[index], proof)).tryGet()

  # Create overlay for protected tree and store all blocks + proofs
  let tmpProtectedCid = (await store.createTmpOverlay()).tryGet()
  for i, blk in datasetBlocks:
    (await store.putBlock(tmpProtectedCid, blk, i)).tryGet()
  (await store.finalizeOverlay(tmpProtectedCid, protectedTreeCid)).tryGet()
  for index, cid in cids:
    let proof = protectedTree.getProof(index).tryGet()
    (await store.putCidAndProof(protectedTreeCid, index, cid, proof)).tryGet()

  let
    manifest = Manifest.new(
      treeCid = datasetTreeCid,
      blockSize = blockSize,
      datasetSize = originalDatasetSize.NBytes,
    )

    protectedManifest = Manifest.new(
      manifest = manifest,
      treeCid = protectedTreeCid,
      datasetSize = totalDatasetSize.NBytes,
      ecK = ecK,
      ecM = ecM,
      strategy = SteppedStrategy,
    )

  discard (await store.storeManifest(manifest)).tryGet()
  discard (await store.storeManifest(protectedManifest)).tryGet()

  (manifest, protectedManifest)

proc createVerifiableManifest*(
    store: RepoStore,
    numDatasetBlocks: int,
    ecK: int,
    ecM: int,
    blockSize: NBytes,
    cellSize: NBytes,
): Future[tuple[manifest: Manifest, protected: Manifest, verifiable: Manifest]] {.
    async
.} =
  let
    numSlots = ecK + ecM
    numTotalBlocks = calcEcBlocksCount(numDatasetBlocks, ecK, ecM)
    originalDatasetSize = numDatasetBlocks * blockSize.int
    totalDatasetSize = numTotalBlocks * blockSize.int

    chunker =
      RandomChunker.new(Rng.instance(), size = totalDatasetSize, chunkSize = blockSize)
    datasetBlocks = await chunker.createBlocks()

    (manifest, protectedManifest) = await createProtectedManifest(
      datasetBlocks, store, numDatasetBlocks, ecK, ecM, blockSize, originalDatasetSize,
      totalDatasetSize,
    )

    builder =
      Poseidon2Builder.new(store, store, protectedManifest, cellSize = cellSize).tryGet
    verifiableManifest = (await builder.buildManifest()).tryGet

  (manifest, protectedManifest, verifiableManifest)
