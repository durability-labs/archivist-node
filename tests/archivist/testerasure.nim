import std/sequtils
import std/sugar
import std/tables

import pkg/chronos
import pkg/questionable/results

import pkg/archivist/erasure
import pkg/archivist/manifest
import pkg/archivist/stores
import pkg/archivist/blocktype as bt
import pkg/archivist/rng
import pkg/archivist/utils
import pkg/archivist/indexingstrategy
import pkg/archivist/archivisttypes
import pkg/archivist/merkletree
import pkg/taskpools

import ../asynctest
import ./helpers
import ./examples

suite "Erasure encode/decode":
  const BlockSize = 1024'nb
  const dataSetSize = BlockSize * 123 # weird geometry

  var rng: Rng
  var chunker: Chunker
  var manifest: Manifest
  var store: BlockStore
  var erasure: Erasure
  let repoTmp = TempLevelDb.new()
  let metaTmp = TempLevelDb.new()
  var taskpool: Taskpool

  setup:
    let
      repoDs = repoTmp.newDb()
      metaDs = metaTmp.newDb()
    rng = Rng.instance()
    chunker = RandomChunker.new(rng, size = dataSetSize, chunkSize = BlockSize)
    store = RepoStore.new(repoDs, metaDs)
    taskpool = Taskpool.new()
    erasure = Erasure.new(store, leoEncoderProvider, leoDecoderProvider, taskpool)
    manifest = await storeDataGetManifest(store, chunker)

  teardown:
    await repoTmp.destroyDb()
    await metaTmp.destroyDb()
    taskpool.shutdown()

  proc encode(buffers, parity: int): Future[Manifest] {.async.} =
    let encoded =
      (await erasure.encode(manifest, buffers.Natural, parity.Natural)).tryGet()

    check:
      encoded.blocksCount mod (buffers + parity) == 0
      encoded.rounded == roundUp(manifest.blocksCount, buffers)
      encoded.steps == encoded.rounded div buffers

    return encoded

  test "Should tolerate losing M data blocks in a single random column":
    const
      buffers = 20
      parity = 10

    let encoded = await encode(buffers, parity)

    var
      column = rng.rand((encoded.blocksCount div encoded.steps) - 1) # random column
      dropped: seq[int]

    for _ in 0 ..< encoded.ecM:
      dropped.add(column)
      (await store.delBlock(encoded.treeCid, column)).tryGet()
      (await store.delBlock(manifest.treeCid, column)).tryGet()
      column = (column + encoded.steps) mod encoded.blocksCount # wrap around

    var decoded = (await erasure.decode(encoded)).tryGet()

    check:
      decoded.treeCid == manifest.treeCid
      decoded.treeCid == encoded.originalTreeCid
      decoded.blocksCount == encoded.originalBlocksCount

    for d in dropped:
      if d < manifest.blocksCount: # we don't support returning parity blocks yet
        let present = await store.hasBlock(manifest.treeCid, d)
        check present.tryGet()

  test "Should not tolerate losing more than M data blocks in a single random column":
    const
      buffers = 20
      parity = 10

    let encoded = await encode(buffers, parity)

    var
      column = rng.rand((encoded.blocksCount div encoded.steps) - 1) # random column
      dropped: seq[int]

    for _ in 0 ..< encoded.ecM + 1:
      dropped.add(column)
      (await store.delBlock(encoded.treeCid, column)).tryGet()
      (await store.delBlock(manifest.treeCid, column)).tryGet()
      column = (column + encoded.steps) mod encoded.blocksCount # wrap around

    var decoded: Manifest

    expect ResultFailure:
      decoded = (await erasure.decode(encoded)).tryGet()

    for d in dropped:
      let present = await store.hasBlock(manifest.treeCid, d)
      check not present.tryGet()

  test "Should tolerate losing M data blocks in M random columns":
    const
      buffers = 20
      parity = 10

    let encoded = await encode(buffers, parity)

    var
      blocks: seq[int]
      offset = 0

    while offset < encoded.steps - 1:
      let blockIdx = toSeq(countup(offset, encoded.blocksCount - 1, encoded.steps))

      for _ in 0 ..< encoded.ecM:
        blocks.add(rng.sample(blockIdx, blocks))
      offset.inc

    for idx in blocks:
      (await store.delBlock(encoded.treeCid, idx)).tryGet()
      (await store.delBlock(manifest.treeCid, idx)).tryGet()
      discard

    discard (await erasure.decode(encoded)).tryGet()

    for d in 0 ..< manifest.blocksCount:
      let present = await store.hasBlock(manifest.treeCid, d)
      check present.tryGet()

  test "Should not tolerate losing more than M data blocks in M random columns":
    const
      buffers = 20
      parity = 10

    let encoded = await encode(buffers, parity)

    var
      blocks: seq[int]
      offset = 0

    while offset < encoded.steps:
      let blockIdx = toSeq(countup(offset, encoded.blocksCount - 1, encoded.steps))

      for _ in 0 ..< encoded.ecM + 1: # NOTE: the +1
        var idx: int
        while true:
          idx = rng.sample(blockIdx, blocks)
          let blk = (await store.getBlock(encoded.treeCid, idx)).tryGet()
          if not blk.isEmpty:
            break

        blocks.add(idx)
      offset.inc

    for idx in blocks:
      (await store.delBlock(encoded.treeCid, idx)).tryGet()
      (await store.delBlock(manifest.treeCid, idx)).tryGet()
      discard

    var decoded: Manifest

    expect ResultFailure:
      decoded = (await erasure.decode(encoded)).tryGet()

  test "Should tolerate losing M (a.k.a row) contiguous data blocks":
    const
      buffers = 20
      parity = 10

    let encoded = await encode(buffers, parity)

    # loose M original (systematic) symbols/blocks
    for b in 0 ..< (encoded.steps * encoded.ecM):
      (await store.delBlock(encoded.treeCid, b)).tryGet()
      (await store.delBlock(manifest.treeCid, b)).tryGet()

    discard (await erasure.decode(encoded)).tryGet()

    for d in 0 ..< manifest.blocksCount:
      let present = await store.hasBlock(manifest.treeCid, d)
      check present.tryGet()

  test "Should tolerate losing M (a.k.a row) contiguous parity blocks":
    const
      buffers = 20
      parity = 10

    let
      encoded = await encode(buffers, parity)
      blocks = collect:
        for i in 0 .. encoded.blocksCount:
          i

    # loose M parity (all!) symbols/blocks from the dataset
    for b in blocks[^(encoded.steps * encoded.ecM) ..^ 1]:
      (await store.delBlock(encoded.treeCid, b)).tryGet()
      (await store.delBlock(manifest.treeCid, b)).tryGet()

    discard (await erasure.decode(encoded)).tryGet()

    for d in 0 ..< manifest.blocksCount:
      let present = await store.hasBlock(manifest.treeCid, d)
      check present.tryGet()

  test "Handles edge case of 0 parity blocks":
    const
      buffers = 20
      parity = 0

    let encoded = await encode(buffers, parity)

    discard (await erasure.decode(encoded)).tryGet()

  test "Should concurrently encode/decode multiple datasets":
    const iterations = 5

    let
      datasetSize = 1.MiBs
      ecK = 10.Natural
      ecM = 10.Natural

    var encodeTasks = newSeq[Future[?!Manifest]]()
    var decodeTasks = newSeq[Future[?!Manifest]]()
    var manifests = newSeq[Manifest]()
    for i in 0 ..< iterations:
      let
        # create random data and store it
        blockSize = rng.sample(@[1, 2, 4, 8, 16, 32, 64].mapIt(it.KiBs))
        chunker = RandomChunker.new(rng, size = datasetSize, chunkSize = blockSize)
        manifest = await storeDataGetManifest(store, chunker)
      manifests.add(manifest)
      # encode the data concurrently
      encodeTasks.add(erasure.encode(manifest, ecK, ecM))
    # wait for all encoding tasks to finish
    let encodeResults = await allFinished(encodeTasks)
    # decode the data concurrently
    for i in 0 ..< encodeResults.len:
      decodeTasks.add(erasure.decode(encodeResults[i].read().tryGet()))
    # wait for all decoding tasks to finish
    let decodeResults = await allFinished(decodeTasks) # TODO: use allFutures

    for j in 0 ..< decodeTasks.len:
      let
        decoded = decodeResults[j].read().tryGet()
        encoded = encodeResults[j].read().tryGet()
      check:
        decoded.treeCid == manifests[j].treeCid
        decoded.treeCid == encoded.originalTreeCid
        decoded.blocksCount == encoded.originalBlocksCount

  test "Should handle verifiable manifests":
    const
      buffers = 20
      parity = 10

    let
      encoded = await encode(buffers, parity)
      slotCids = collect(newSeq):
        for i in 0 ..< encoded.numSlots:
          Cid.example

      verifiable = Manifest.new(encoded, Cid.example, slotCids).tryGet()

      decoded = (await erasure.decode(verifiable)).tryGet()

    check:
      decoded.treeCid == manifest.treeCid
      decoded.treeCid == verifiable.originalTreeCid
      decoded.blocksCount == verifiable.originalBlocksCount

  test "Should reject encoding already-protected manifest":
    const
      ecK = 10
      ecM = 5

    let encoded = (await erasure.encode(manifest, ecK.Natural, ecM.Natural)).tryGet()

    # Trying to encode an already-protected manifest should fail
    let result = await erasure.encode(encoded, ecK.Natural, ecM.Natural)
    check result.isErr
    check "already-protected" in result.error.msg
    check "original unprotected" in result.error.msg

  for i in 1 .. 5:
    test "Should encode/decode using various parameters " & $i & "/5":
      let
        blockSize = rng.sample(@[1, 2, 4, 8, 16, 32, 64].mapIt(it.KiBs))
        datasetSize = 1.MiBs
        ecK = 10.Natural
        ecM = 10.Natural

      let
        chunker = RandomChunker.new(rng, size = datasetSize, chunkSize = blockSize)
        manifest = await storeDataGetManifest(store, chunker)
        encoded = (await erasure.encode(manifest, ecK, ecM)).tryGet()
        decoded = (await erasure.decode(encoded)).tryGet()

      check:
        decoded.treeCid == manifest.treeCid
        decoded.treeCid == encoded.originalTreeCid
        decoded.blocksCount == encoded.originalBlocksCount

  test "Should complete encode/decode task when cancelled":
    let
      blocksLen = 10000
      chunker = RandomChunker.new(
        rng, size = (blocksLen * BlockSize.int), chunkSize = BlockSize
      )

    let data = new seq[seq[byte]]
    let parity = new seq[seq[byte]]
    let recovered = new seq[seq[byte]]
    let cancelledTaskParity = new seq[seq[byte]]
    let cancelledTaskRecovered = new seq[seq[byte]]
    data[] = newSeqWith(blocksLen, await chunker.getBytes())
    parity[] = newSeqWith(10, newSeqWith(BlockSize.int, 0'u8))
    cancelledTaskParity[] = newSeqWith(10, newSeqWith(BlockSize.int, 0'u8))
    recovered[] = newSeqWith(blocksLen, newSeqWith(BlockSize.int, 0'u8))
    cancelledTaskRecovered[] = newSeqWith(blocksLen, newSeqWith(BlockSize.int, 0'u8))

    # call asyncEncode to get the parity
    let encFut = await erasure.asyncEncode(BlockSize.int, data, parity)
    check encFut.isOk

    let decFut = await erasure.asyncDecode(BlockSize.int, data, parity, recovered)
    check decFut.isOk

    # call asyncEncode and cancel the task
    let encodeFut = erasure.asyncEncode(BlockSize.int, data, cancelledTaskParity)
    await encodeFut.cancelAndWait()

    try:
      discard await encodeFut
    except CatchableError as exc:
      check exc of CancelledError
    finally:
      check parity[] == cancelledTaskParity[]

    # call asyncDecode and cancel the task
    let decodeFut =
      erasure.asyncDecode(BlockSize.int, data, parity, cancelledTaskRecovered)
    await decodeFut.cancelAndWait()

    try:
      discard await decodeFut
    except CatchableError as exc:
      check exc of CancelledError
    finally:
      check recovered[] == cancelledTaskRecovered[]

suite "Erasure encode/decode - Directory manifests":
  const BlockSize = 1024'nb
  const FileSize = BlockSize * 10

  var rng: Rng
  var store: BlockStore
  var erasure: Erasure
  let repoTmp = TempLevelDb.new()
  let metaTmp = TempLevelDb.new()
  var taskpool: Taskpool

  setup:
    let
      repoDs = repoTmp.newDb()
      metaDs = metaTmp.newDb()
    rng = Rng.instance()
    store = RepoStore.new(repoDs, metaDs)
    taskpool = Taskpool.new()
    erasure = Erasure.new(store, leoEncoderProvider, leoDecoderProvider, taskpool)

  teardown:
    await repoTmp.destroyDb()
    await metaTmp.destroyDb()
    taskpool.shutdown()

  proc createFileManifest(size: int = FileSize.int): Future[Manifest] {.async.} =
    ## Helper to create and store a file manifest
    let chunker = RandomChunker.new(rng, size = size, chunkSize = BlockSize)
    return await storeDataGetManifest(store, chunker)

  proc storeManifestBlk(manifest: Manifest): Future[Cid] {.async.} =
    ## Helper to store a manifest and return its CID
    let encoded = manifest.encode().tryGet()
    let blk = bt.Block.new(data = encoded, codec = ManifestCodec).tryGet()
    (await store.putBlock(blk)).tryGet()
    return blk.cid

  proc fetchManifest(cid: Cid): Future[Manifest] {.async.} =
    ## Helper to fetch a manifest by CID
    let blk = (await store.getBlock(cid)).tryGet()
    return Manifest.decode(blk).tryGet()

  proc createDirectoryManifest(
      name: string, entries: OrderedTable[string, Cid]
  ): Future[Manifest] {.async.} =
    ## Helper to create a directory manifest with a proper treeCid
    # Build tree from entry CIDs (the manifest CIDs)
    var entryCids: seq[Cid]
    for path, cid in entries.pairs:
      entryCids.add(cid)

    let tree = ArchivistTree.init(entryCids).tryGet()
    let treeCid = tree.rootCid.tryGet()

    # Note: We don't store proofs here because directory entries are manifest CIDs,
    # not block CIDs. The directory tree is just used to generate treeCid.

    # Calculate total size from entries
    var totalSize: NBytes = 0.NBytes
    for path, cid in entries.pairs:
      let manifest = await fetchManifest(cid)
      totalSize = totalSize + manifest.datasetSize

    return Manifest.new(
      treeCid = treeCid,
      blockSize = BlockSize,
      datasetSize = totalSize,
      name = name,
      entries = entries,
    )

  test "Should encode directory with multiple files":
    const
      ecK = 3
      ecM = 2

    # Create file manifests
    let
      file1 = await createFileManifest()
      file2 = await createFileManifest()
      file3 = await createFileManifest()

    # Store manifests and get CIDs
    let
      cid1 = await storeManifestBlk(file1)
      cid2 = await storeManifestBlk(file2)
      cid3 = await storeManifestBlk(file3)

    # Create directory manifest
    var entries: OrderedTable[string, Cid]
    entries["photos/img1.jpg"] = cid1
    entries["photos/img2.jpg"] = cid2
    entries["docs/readme.md"] = cid3

    let dirManifest = await createDirectoryManifest("TestAlbum", entries)

    # Encode directory
    let encoded = (await erasure.encode(dirManifest, ecK.Natural, ecM.Natural)).tryGet()

    check:
      encoded.isDirectory == true
      encoded.protected == true
      encoded.ecK == ecK
      encoded.ecM == ecM
      encoded.entries.len == 3

    # Verify each entry points to a protected manifest
    for path, entryCid in encoded.entries.pairs:
      let entryManifest = await fetchManifest(entryCid)
      check:
        entryManifest.protected == true
        entryManifest.ecK == ecK
        entryManifest.ecM == ecM

  test "Should reuse already protected files with matching params":
    const
      ecK = 3
      ecM = 2

    # Create and encode a file manifest first
    let originalFile = await createFileManifest()
    let protectedFile =
      (await erasure.encode(originalFile, ecK.Natural, ecM.Natural)).tryGet()
    let protectedCid = await storeManifestBlk(protectedFile)

    # Create directory with the already-protected file
    var entries: OrderedTable[string, Cid]
    entries["already_protected.dat"] = protectedCid

    let dirManifest = await createDirectoryManifest("TestDir", entries)

    # Encode directory
    let encoded = (await erasure.encode(dirManifest, ecK.Natural, ecM.Natural)).tryGet()

    # The entry CID should be the same (reused, not re-encoded)
    check encoded.entries["already_protected.dat"] == protectedCid

  test "Should reject directory with entries protected using different params":
    const
      ecK1 = 3
      ecM1 = 2
      ecK2 = 5
      ecM2 = 3

    # Create and encode a file with certain params
    let originalFile = await createFileManifest()
    let protectedFile =
      (await erasure.encode(originalFile, ecK1.Natural, ecM1.Natural)).tryGet()
    let protectedCid = await storeManifestBlk(protectedFile)

    # Create directory with the protected file
    var entries: OrderedTable[string, Cid]
    entries["file.dat"] = protectedCid

    let dirManifest = await createDirectoryManifest("TestDir", entries)

    # Trying to encode directory with different params should fail
    let result = await erasure.encode(dirManifest, ecK2.Natural, ecM2.Natural)
    check result.isErr
    check "different EC params" in result.error.msg
    check "original unprotected" in result.error.msg

  test "Should encode single file directory":
    const
      ecK = 3
      ecM = 2

    let file1 = await createFileManifest()
    let cid1 = await storeManifestBlk(file1)

    var entries: OrderedTable[string, Cid]
    entries["single.txt"] = cid1

    let dirManifest = await createDirectoryManifest("SingleFileDir", entries)

    let encoded = (await erasure.encode(dirManifest, ecK.Natural, ecM.Natural)).tryGet()

    check:
      encoded.isDirectory == true
      encoded.protected == true
      encoded.entries.len == 1

  test "Directory encoding preserves entry order":
    const
      ecK = 3
      ecM = 2

    let
      file1 = await createFileManifest()
      file2 = await createFileManifest()
      file3 = await createFileManifest()

    let
      cid1 = await storeManifestBlk(file1)
      cid2 = await storeManifestBlk(file2)
      cid3 = await storeManifestBlk(file3)

    # Create entries in specific order
    var entries: OrderedTable[string, Cid]
    entries["z_last.txt"] = cid1
    entries["a_first.txt"] = cid2
    entries["m_middle.txt"] = cid3

    let dirManifest = await createDirectoryManifest("OrderedDir", entries)

    let encoded = (await erasure.encode(dirManifest, ecK.Natural, ecM.Natural)).tryGet()

    # Verify order is preserved
    var keys: seq[string]
    for key in encoded.entries.keys:
      keys.add(key)

    check:
      keys[0] == "z_last.txt"
      keys[1] == "a_first.txt"
      keys[2] == "m_middle.txt"

  test "Directory encoding aggregates total dataset size":
    const
      ecK = 3
      ecM = 2

    let
      file1 = await createFileManifest(FileSize.int)
      file2 = await createFileManifest(FileSize.int * 2)

    let
      cid1 = await storeManifestBlk(file1)
      cid2 = await storeManifestBlk(file2)

    var entries: OrderedTable[string, Cid]
    entries["small.dat"] = cid1
    entries["large.dat"] = cid2

    let dirManifest = await createDirectoryManifest("SizeTestDir", entries)

    let encoded = (await erasure.encode(dirManifest, ecK.Natural, ecM.Natural)).tryGet()

    # Get the protected file sizes
    var totalExpectedSize: NBytes = 0.NBytes
    for path, entryCid in encoded.entries.pairs:
      let entryManifest = await fetchManifest(entryCid)
      totalExpectedSize = totalExpectedSize + entryManifest.datasetSize

    check encoded.datasetSize == totalExpectedSize
