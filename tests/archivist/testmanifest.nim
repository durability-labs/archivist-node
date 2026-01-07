import std/tables
import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/libp2p
import pkg/archivist/chunker
import pkg/archivist/blocktype as bt
import pkg/archivist/manifest
import pkg/poseidon2

import pkg/archivist/slots
import pkg/archivist/merkletree
import pkg/archivist/indexingstrategy
import pkg/archivist/utils/fileutils

import ../asynctest
import ./helpers
import ./examples

proc encodeDecode(manifest: Manifest): Manifest =
  let e = manifest.encode().tryGet()
  Manifest.decode(e).tryGet()

suite "Manifest":
  let
    manifest =
      Manifest.new(treeCid = Cid.example, blockSize = 1.MiBs, datasetSize = 100.MiBs)

    protectedManifest = Manifest.new(
      manifest = manifest,
      treeCid = Cid.example,
      datasetSize = 200.MiBs,
      eck = 2,
      ecM = 2,
      strategy = SteppedStrategy,
    )

    leaves = [
      0.toF.Poseidon2Hash, 1.toF.Poseidon2Hash, 2.toF.Poseidon2Hash, 3.toF.Poseidon2Hash
    ]

    slotLeavesCids = leaves.toSlotCids().tryGet

    tree = Poseidon2Tree.init(leaves).tryGet
    verifyCid = tree.root.tryGet.toVerifyCid().tryGet

    verifiableManifest = Manifest
      .new(
        manifest = protectedManifest, verifyRoot = verifyCid, slotRoots = slotLeavesCids
      )
      .tryGet()

  test "Should encode/decode to/from base manifest":
    check:
      encodeDecode(manifest) == manifest

  test "Should encode/decode large manifest":
    let large = Manifest.new(
      treeCid = Cid.example,
      blockSize = (64 * 1024).NBytes,
      datasetSize = (5 * 1024).MiBs,
    )

    check:
      encodeDecode(large) == large

  test "Should encode/decode to/from protected manifest":
    check:
      encodeDecode(protectedManifest) == protectedManifest

  test "Should encode/decode to/from verifiable manifest":
    check:
      encodeDecode(verifiableManifest) == verifiableManifest

suite "Manifest - Attribute Inheritance":
  proc makeProtectedManifest(strategy: StrategyType): Manifest =
    Manifest.new(
      manifest = Manifest.new(
        treeCid = Cid.example,
        blockSize = 1.MiBs,
        datasetSize = 5.MiBs,
        path = "example.png".some,
        mimetype = "image/png".some,
      ),
      treeCid = Cid.example,
      datasetSize = 10.MiBs,
      ecK = 1,
      ecM = 1,
      strategy = strategy,
    )

  test "Should preserve interleaving strategy for protected manifest in verifiable manifest":
    var verifiable = Manifest
      .new(
        manifest = makeProtectedManifest(SteppedStrategy),
        verifyRoot = Cid.example,
        slotRoots = @[Cid.example, Cid.example],
      )
      .tryGet()

    check verifiable.protectedStrategy == SteppedStrategy

    verifiable = Manifest
      .new(
        manifest = makeProtectedManifest(LinearStrategy),
        verifyRoot = Cid.example,
        slotRoots = @[Cid.example, Cid.example],
      )
      .tryGet()

    check verifiable.protectedStrategy == LinearStrategy

  test "Should preserve metadata for manifest in verifiable manifest":
    var verifiable = Manifest
      .new(
        manifest = makeProtectedManifest(SteppedStrategy),
        verifyRoot = Cid.example,
        slotRoots = @[Cid.example, Cid.example],
      )
      .tryGet()

    check verifiable.path.isSome == true
    check verifiable.path.get() == "example.png"
    check verifiable.mimetype.isSome == true
    check verifiable.mimetype.get() == "image/png"

  test "Can provide slot block iterator for verifiable manifest":
    var verifiable = Manifest
      .new(
        manifest = makeProtectedManifest(SteppedStrategy),
        verifyRoot = Cid.example,
        slotRoots = @[Cid.example, Cid.example],
      )
      .tryGet()

    let iter0 = verifiable.getSlotBlockIterator(0).tryGet()
    let iter1 = verifiable.getSlotBlockIterator(1).tryGet()
    check:
      iter0.next() == 0
      iter0.next() == 1
      iter0.next() == 2
      iter0.next() == 3
      iter0.next() == 4
      iter0.finished

      iter1.next() == 5
      iter1.next() == 6
      iter1.next() == 7
      iter1.next() == 8
      iter1.next() == 9
      iter1.finished

suite "Manifest - Directory Support":
  test "Should create unprotected directory manifest":
    var entries: OrderedTable[string, Cid]
    entries["photos/img1.jpg"] = Cid.example
    entries["photos/img2.jpg"] = Cid.example
    entries["docs/readme.md"] = Cid.example

    let dirManifest = Manifest.new(
      treeCid = Cid.example,
      blockSize = 1.MiBs,
      datasetSize = 10.MiBs,
      name = "MyAlbum",
      entries = entries,
    )

    check:
      dirManifest.isDirectory == true
      dirManifest.name == "MyAlbum"
      dirManifest.entries.len == 3
      dirManifest.fileCount == 3
      dirManifest.protected == false
      "photos/img1.jpg" in dirManifest.entries
      "photos/img2.jpg" in dirManifest.entries
      "docs/readme.md" in dirManifest.entries

  test "Should encode/decode unprotected directory manifest":
    var entries: OrderedTable[string, Cid]
    entries["file1.txt"] = Cid.example
    entries["folder/file2.txt"] = Cid.example

    let dirManifest = Manifest.new(
      treeCid = Cid.example,
      blockSize = 1.MiBs,
      datasetSize = 5.MiBs,
      name = "TestDir",
      entries = entries,
    )

    let decoded = encodeDecode(dirManifest)

    check:
      decoded == dirManifest
      decoded.isDirectory == true
      decoded.name == "TestDir"
      decoded.entries.len == 2
      decoded.fileCount == 2
      decoded.protected == false

  test "Should preserve entry order in directory manifest":
    var entries: OrderedTable[string, Cid]
    # Add entries in specific order
    entries["z_last.txt"] = Cid.example
    entries["a_first.txt"] = Cid.example
    entries["m_middle.txt"] = Cid.example

    let dirManifest = Manifest.new(
      treeCid = Cid.example,
      blockSize = 1.MiBs,
      datasetSize = 3.MiBs,
      name = "OrderedDir",
      entries = entries,
    )

    let decoded = encodeDecode(dirManifest)

    # Verify order is preserved
    var keys: seq[string]
    for path in decoded.entries.keys:
      keys.add(path)

    check:
      keys[0] == "z_last.txt"
      keys[1] == "a_first.txt"
      keys[2] == "m_middle.txt"

  test "Should create protected directory manifest from unprotected":
    var entries: OrderedTable[string, Cid]
    entries["file1.txt"] = Cid.example
    entries["file2.txt"] = Cid.example

    let unprotectedDir = Manifest.new(
      treeCid = Cid.example,
      blockSize = 1.MiBs,
      datasetSize = 5.MiBs,
      name = "ProtectedDir",
      entries = entries,
    )

    let protectedDir = Manifest.new(
      manifest = unprotectedDir,
      treeCid = Cid.example,
      datasetSize = 10.MiBs,
      ecK = 2,
      ecM = 1,
      strategy = LinearStrategy,
    )

    check:
      protectedDir.isDirectory == true
      protectedDir.name == "ProtectedDir"
      protectedDir.entries.len == 2
      protectedDir.protected == true
      protectedDir.ecK == 2
      protectedDir.ecM == 1
      protectedDir.protectedStrategy == LinearStrategy

  test "Should encode/decode protected directory manifest":
    var entries: OrderedTable[string, Cid]
    entries["data/file.bin"] = Cid.example

    let unprotectedDir = Manifest.new(
      treeCid = Cid.example,
      blockSize = 1.MiBs,
      datasetSize = 5.MiBs,
      name = "EncodeTest",
      entries = entries,
    )

    let protectedDir = Manifest.new(
      manifest = unprotectedDir,
      treeCid = Cid.example,
      datasetSize = 10.MiBs,
      ecK = 3,
      ecM = 2,
      strategy = SteppedStrategy,
    )

    let decoded = encodeDecode(protectedDir)

    check:
      decoded == protectedDir
      decoded.isDirectory == true
      decoded.name == "EncodeTest"
      decoded.entries.len == 1
      decoded.protected == true
      decoded.ecK == 3
      decoded.ecM == 2

  test "Should create verifiable directory manifest":
    var entries: OrderedTable[string, Cid]
    entries["verify/file.txt"] = Cid.example

    let unprotectedDir = Manifest.new(
      treeCid = Cid.example,
      blockSize = 1.MiBs,
      datasetSize = 5.MiBs,
      name = "VerifiableDir",
      entries = entries,
    )

    let protectedDir = Manifest.new(
      manifest = unprotectedDir,
      treeCid = Cid.example,
      datasetSize = 12.MiBs,
      ecK = 2,
      ecM = 2,
      strategy = SteppedStrategy,
    )

    let verifiableDir = Manifest
      .new(
        manifest = protectedDir,
        verifyRoot = Cid.example,
        slotRoots = @[Cid.example, Cid.example, Cid.example, Cid.example],
      )
      .tryGet()

    check:
      verifiableDir.isDirectory == true
      verifiableDir.name == "VerifiableDir"
      verifiableDir.entries.len == 1
      verifiableDir.protected == true
      verifiableDir.verifiable == true
      verifiableDir.slotRoots.len == 4

  test "Should encode/decode verifiable directory manifest":
    var entries: OrderedTable[string, Cid]
    entries["a.txt"] = Cid.example
    entries["b.txt"] = Cid.example

    let unprotectedDir = Manifest.new(
      treeCid = Cid.example,
      blockSize = 1.MiBs,
      datasetSize = 5.MiBs,
      name = "VerifyEncode",
      entries = entries,
    )

    let protectedDir = Manifest.new(
      manifest = unprotectedDir,
      treeCid = Cid.example,
      datasetSize = 12.MiBs,
      ecK = 2,
      ecM = 2,
      strategy = LinearStrategy,
    )

    let verifiableDir = Manifest
      .new(
        manifest = protectedDir,
        verifyRoot = Cid.example,
        slotRoots = @[Cid.example, Cid.example, Cid.example, Cid.example],
      )
      .tryGet()

    let decoded = encodeDecode(verifiableDir)

    check:
      decoded == verifiableDir
      decoded.isDirectory == true
      decoded.name == "VerifyEncode"
      decoded.entries.len == 2
      decoded.verifiable == true

  test "Non-directory manifest should have isDirectory false":
    let fileManifest = Manifest.new(
      treeCid = Cid.example,
      blockSize = 1.MiBs,
      datasetSize = 5.MiBs,
      path = "regular_file.txt".some,
    )

    check:
      fileManifest.isDirectory == false
      fileManifest.fileCount == 0

  test "Should encode/decode file manifest with path":
    let fileManifest = Manifest.new(
      treeCid = Cid.example,
      blockSize = 1.MiBs,
      datasetSize = 5.MiBs,
      path = "photos/vacation/beach.jpg".some,
      mimetype = "image/jpeg".some,
    )

    let decoded = encodeDecode(fileManifest)

    check:
      decoded == fileManifest
      decoded.isDirectory == false
      decoded.path.isSome == true
      decoded.mimetype.isSome == true

    # Use without pattern to safely access optional values
    without decodedPath =? decoded.path:
      fail()
    check decodedPath == "photos/vacation/beach.jpg"

    without decodedMimetype =? decoded.mimetype:
      fail()
    check decodedMimetype == "image/jpeg"

  test "filename() should extract filename from path":
    let withPath = Manifest.new(
      treeCid = Cid.example,
      blockSize = 1.MiBs,
      datasetSize = 5.MiBs,
      path = "photos/vacation/beach.jpg".some,
    )

    let simpleFile = Manifest.new(
      treeCid = Cid.example,
      blockSize = 1.MiBs,
      datasetSize = 5.MiBs,
      path = "readme.txt".some,
    )

    let noPath = Manifest.new(
      treeCid = Cid.example,
      blockSize = 1.MiBs,
      datasetSize = 5.MiBs,
    )

    check:
      withPath.filename.isSome == true
      withPath.filename.get() == "beach.jpg"
      simpleFile.filename.isSome == true
      simpleFile.filename.get() == "readme.txt"
      noPath.filename.isNone == true

  test "Directory manifest string representation includes directory info":
    var entries: OrderedTable[string, Cid]
    entries["test.txt"] = Cid.example

    let dirManifest = Manifest.new(
      treeCid = Cid.example,
      blockSize = 1.MiBs,
      datasetSize = 1.MiBs,
      name = "StringTest",
      entries = entries,
    )

    let str = $dirManifest
    check:
      "isDirectory: true" in str
      "name: StringTest" in str
      "fileCount: 1" in str

suite "Directory Decoder Validation":
  # Helper to create raw protobuf for testing decoder validation
  proc makeRawManifest(
      withName: bool, withEntries: bool
  ): seq[byte] =
    # Create a basic manifest with optional directory fields
    var header = initProtoBuffer()
    let treeCidBytes = Cid.example.data.buffer

    header.write(1, treeCidBytes) # treeCid
    header.write(2, uint32(1024 * 1024)) # blockSize (1 MiB)
    header.write(3, uint64(5 * 1024 * 1024)) # datasetSize (5 MiB)
    header.write(4, uint32(multiCodec("raw"))) # codec
    header.write(5, uint32(Sha256HashCodec)) # hcodec
    header.write(6, uint32(CIDv1)) # version

    if withName:
      header.write(10, "TestDirectory") # directoryName

    if withEntries:
      var entryBuf = initProtoBuffer()
      entryBuf.write(1, "file.txt") # entry path
      entryBuf.write(2, treeCidBytes) # entry CID (reuse treeCid for simplicity)
      entryBuf.finish()
      header.write(11, entryBuf) # entries

    header.finish()

    var pbNode = initProtoBuffer()
    pbNode.write(1, header)
    pbNode.finish()

    return pbNode.buffer

  test "Decoder should fail when directory has name but no entries":
    let rawData = makeRawManifest(withName = true, withEntries = false)
    let result = Manifest.decode(rawData)

    check result.isErr
    check "name but no entries" in result.error.msg

  test "Decoder should fail when directory has entries but no name":
    let rawData = makeRawManifest(withName = false, withEntries = true)
    let result = Manifest.decode(rawData)

    check result.isErr
    check "entries but no name" in result.error.msg

  test "Decoder should succeed when directory has both name and entries":
    let rawData = makeRawManifest(withName = true, withEntries = true)
    let result = Manifest.decode(rawData)

    check result.isOk
    let manifest = result.tryGet()
    check manifest.isDirectory == true
    check manifest.name == "TestDirectory"
    check manifest.entries.len == 1

  test "Decoder should succeed when manifest has neither name nor entries":
    let rawData = makeRawManifest(withName = false, withEntries = false)
    let result = Manifest.decode(rawData)

    check result.isOk
    let manifest = result.tryGet()
    check manifest.isDirectory == false

suite "Path Validation":
  test "Empty path is valid (file goes in root using CID as name)":
    check isValidVirtualPath("") == true

  test "Simple filename is valid":
    check isValidVirtualPath("file.txt") == true

  test "Path with subdirectory is valid":
    check isValidVirtualPath("photos/image.jpg") == true

  test "Deep nested path is valid":
    check isValidVirtualPath("a/b/c/d/e/file.txt") == true

  test "Path with dots in filename is valid":
    check isValidVirtualPath("archive.tar.gz") == true

  test "Path with dot directory is valid":
    check isValidVirtualPath("./file.txt") == true

  test "Path with parent traversal is invalid":
    check isValidVirtualPath("../etc/passwd") == false
    check isValidVirtualPath("folder/../secret") == false
    check isValidVirtualPath("a/b/../../c") == false

  test "Absolute path is invalid":
    check isValidVirtualPath("/etc/passwd") == false
    check isValidVirtualPath("/home/user/file") == false

  test "Path with backslash is invalid":
    check isValidVirtualPath("folder\\file.txt") == false
    check isValidVirtualPath("a\\b\\c") == false

  test "Path with null byte is invalid":
    check isValidVirtualPath("file\x00.txt") == false

  test "Path with trailing slash is invalid":
    check isValidVirtualPath("folder/") == false

  test "Path with consecutive slashes is invalid":
    check isValidVirtualPath("folder//file.txt") == false

  test "Path exceeding max depth is invalid":
    # Create path with 21 levels (exceeds MaxPathDepth of 20)
    var deepPath = "a"
    for i in 1 ..< 22:
      deepPath &= "/b"
    check isValidVirtualPath(deepPath) == false

  test "Path at max depth is valid":
    # Create path with exactly 20 levels
    var maxPath = "a"
    for i in 1 ..< 20:
      maxPath &= "/b"
    check isValidVirtualPath(maxPath) == true

  test "Very long path is invalid":
    let longPath = "a".repeat(MaxPathLength + 1)
    check isValidVirtualPath(longPath) == false

  test "Path at max length is valid":
    let maxLengthPath = "a".repeat(MaxPathLength)
    check isValidVirtualPath(maxLengthPath) == true
