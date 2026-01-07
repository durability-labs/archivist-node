## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# This module defines all operations on Manifest

{.push raises: [].}

import std/tables
import std/os

import pkg/libp2p/protobuf/minprotobuf
import pkg/libp2p/[cid, multihash, multicodec]
import pkg/questionable/results

import ../errors
import ../utils
import ../utils/json
import ../units
import ../blocktype
import ../indexingstrategy
import ../logutils

type Manifest* = ref object of RootObj
  treeCid {.serialize.}: Cid # Root of the merkle tree
  datasetSize {.serialize.}: NBytes # Total size of all blocks
  blockSize {.serialize.}: NBytes
    # Size of each contained block (might not be needed if blocks are len-prefixed)
  codec: MultiCodec # Dataset codec
  hcodec: MultiCodec # Multihash codec
  version: CidVersion # Cid version
  path {.serialize.}: ?string # Virtual path of the file within directory (optional)
  mimetype {.serialize.}: ?string # The mimetype of the content uploaded (optional)
  case isDirectory* {.serialize.}: bool # Directory manifests contain file entries
  of true:
    name {.serialize.}: string # Directory name
    entries {.serialize.}: OrderedTable[string, Cid] # Path -> Manifest CID mapping
  else:
    discard
  case protected {.serialize.}: bool # Protected datasets have erasure coded info
  of true:
    ecK: int # Number of blocks to encode
    ecM: int # Number of resulting parity blocks
    originalTreeCid: Cid # The original root of the dataset being erasure coded
    originalDatasetSize: NBytes
    protectedStrategy: StrategyType # Indexing strategy used to build the slot roots
    case verifiable {.serialize.}: bool
    # Verifiable datasets can be used to generate storage proofs
    of true:
      verifyRoot: Cid # Root of the top level merkle tree built from slot roots
      slotRoots: seq[Cid] # Individual slot root built from the original dataset blocks
      cellSize: NBytes # Size of each slot cell
      verifiableStrategy: StrategyType # Indexing strategy used to build the slot roots
    else:
      discard
  else:
    discard

############################################################
# Accessors
############################################################

func blockSize*(self: Manifest): NBytes =
  self.blockSize

func datasetSize*(self: Manifest): NBytes =
  self.datasetSize

func version*(self: Manifest): CidVersion =
  self.version

func hcodec*(self: Manifest): MultiCodec =
  self.hcodec

func codec*(self: Manifest): MultiCodec =
  self.codec

func protected*(self: Manifest): bool =
  self.protected

func ecK*(self: Manifest): int =
  self.ecK

func ecM*(self: Manifest): int =
  self.ecM

func originalTreeCid*(self: Manifest): Cid =
  self.originalTreeCid

func originalBlocksCount*(self: Manifest): int =
  divUp(self.originalDatasetSize.int, self.blockSize.int)

func originalDatasetSize*(self: Manifest): NBytes =
  self.originalDatasetSize

func treeCid*(self: Manifest): Cid =
  self.treeCid

func blocksCount*(self: Manifest): int =
  divUp(self.datasetSize.int, self.blockSize.int)

func verifiable*(self: Manifest): bool =
  bool (self.protected and self.verifiable)

func verifyRoot*(self: Manifest): Cid =
  self.verifyRoot

func slotRoots*(self: Manifest): seq[Cid] =
  self.slotRoots

func numSlots*(self: Manifest): int =
  self.ecK + self.ecM

func cellSize*(self: Manifest): NBytes =
  self.cellSize

func protectedStrategy*(self: Manifest): StrategyType =
  self.protectedStrategy

func verifiableStrategy*(self: Manifest): StrategyType =
  self.verifiableStrategy

func numSlotBlocks*(self: Manifest): int =
  divUp(self.blocksCount, self.numSlots)

func path*(self: Manifest): ?string =
  self.path

func filename*(self: Manifest): ?string =
  ## Returns just the filename from the path (without directory components)
  ## e.g., "photos/vacation/beach.jpg" -> "beach.jpg"
  if path =? self.path:
    return path.extractFilename().some
  string.none

func mimetype*(self: Manifest): ?string =
  self.mimetype

func isDirectory*(self: Manifest): bool =
  self.isDirectory

func name*(self: Manifest): string =
  self.name

func entries*(self: Manifest): OrderedTable[string, Cid] =
  self.entries

func `entries=`*(self: Manifest, entries: OrderedTable[string, Cid]) =
  self.entries = entries

func fileCount*(self: Manifest): int =
  ## Returns the number of files in a directory manifest
  if self.isDirectory:
    self.entries.len
  else:
    0

############################################################
# Operations on block list
############################################################

func isManifest*(cid: Cid): ?!bool =
  success (ManifestCodec == ?cid.contentType().mapFailure(ArchivistError))

func isManifest*(mc: MultiCodec): ?!bool =
  success mc == ManifestCodec

proc getSlotBlockIterator*(self: Manifest, slotIdx: int): ?!Iter[int] =
  if not self.protected:
    return failure("Manifest is not protected")
  if not self.verifiable:
    return failure("Manifest is not verifiable")

  without indexer =?
    self.verifiableStrategy.init(0, self.blocksCount - 1, self.numSlots).catch, err:
    error "Unable to create indexing strategy from protected manifest", err = err.msg
    return failure(err)

  without blksIter =? indexer.getIndices(slotIdx).catch, err:
    error "Unable to get indices from strategy", err = err.msg
    return failure(err)
  return success(blksIter)

############################################################
# Various sizes and verification
############################################################

func rounded*(self: Manifest): int =
  ## Number of data blocks in *protected* manifest including padding at the end
  roundUp(self.originalBlocksCount, self.ecK)

func steps*(self: Manifest): int =
  ## Number of EC groups in *protected* manifest
  divUp(self.rounded, self.ecK)

func verify*(self: Manifest): ?!void =
  ## Check manifest correctness
  ##

  if self.protected and (self.blocksCount != self.steps * (self.ecK + self.ecM)):
    return
      failure newException(ArchivistError, "Broken manifest: wrong originalBlocksCount")

  return success()

func `==`*(a, b: Manifest): bool =
  (a.treeCid == b.treeCid) and (a.datasetSize == b.datasetSize) and
    (a.blockSize == b.blockSize) and (a.version == b.version) and (a.hcodec == b.hcodec) and
    (a.codec == b.codec) and (a.protected == b.protected) and (a.path == b.path) and
    (a.mimetype == b.mimetype) and (a.isDirectory == b.isDirectory) and (
    if a.isDirectory:
      (a.name == b.name) and (a.entries == b.entries)
    else:
      true
  ) and (
    if a.protected:
      (a.ecK == b.ecK) and (a.ecM == b.ecM) and (a.originalTreeCid == b.originalTreeCid) and
        (a.originalDatasetSize == b.originalDatasetSize) and
        (a.protectedStrategy == b.protectedStrategy) and (a.verifiable == b.verifiable) and
      (
        if a.verifiable:
          (a.verifyRoot == b.verifyRoot) and (a.slotRoots == b.slotRoots) and
            (a.cellSize == b.cellSize) and (
            a.verifiableStrategy == b.verifiableStrategy
          )
        else:
          true
      )
    else:
      true
  )

func `$`*(self: Manifest): string =
  result =
    "treeCid: " & $self.treeCid & ", datasetSize: " & $self.datasetSize & ", blockSize: " &
    $self.blockSize & ", version: " & $self.version & ", hcodec: " & $self.hcodec &
    ", codec: " & $self.codec & ", protected: " & $self.protected &
    ", isDirectory: " & $self.isDirectory

  if self.path.isSome:
    result &= ", path: " & $self.path

  if self.mimetype.isSome:
    result &= ", mimetype: " & $self.mimetype

  if self.isDirectory:
    result &= ", name: " & self.name & ", fileCount: " & $self.entries.len

  result &= (
    if self.protected:
      ", ecK: " & $self.ecK & ", ecM: " & $self.ecM & ", originalTreeCid: " &
        $self.originalTreeCid & ", originalDatasetSize: " & $self.originalDatasetSize &
        ", verifiable: " & $self.verifiable & (
        if self.verifiable:
          ", verifyRoot: " & $self.verifyRoot & ", slotRoots: " & $self.slotRoots
        else:
          ""
      )
    else:
      ""
  )

  return result

############################################################
# Constructors
############################################################

func new*(
    T: type Manifest,
    treeCid: Cid,
    blockSize: NBytes,
    datasetSize: NBytes,
    version: CidVersion = CIDv1,
    hcodec = Sha256HashCodec,
    codec = BlockCodec,
    protected = false,
    path: ?string = string.none,
    mimetype: ?string = string.none,
): Manifest =
  ## Create a new file manifest (non-directory)
  T(
    treeCid: treeCid,
    blockSize: blockSize,
    datasetSize: datasetSize,
    version: version,
    codec: codec,
    hcodec: hcodec,
    protected: protected,
    path: path,
    mimetype: mimetype,
    isDirectory: false,
  )

func new*(
    T: type Manifest,
    manifest: Manifest,
    treeCid: Cid,
    datasetSize: NBytes,
    ecK, ecM: int,
    strategy = SteppedStrategy,
): Manifest =
  ## Create an erasure protected dataset from an
  ## unprotected one
  ##

  var self = Manifest(
    treeCid: treeCid,
    datasetSize: datasetSize,
    version: manifest.version,
    codec: manifest.codec,
    hcodec: manifest.hcodec,
    blockSize: manifest.blockSize,
    protected: true,
    ecK: ecK,
    ecM: ecM,
    originalTreeCid: manifest.treeCid,
    originalDatasetSize: manifest.datasetSize,
    protectedStrategy: strategy,
    path: manifest.path,
    mimetype: manifest.mimetype,
    isDirectory: manifest.isDirectory,
  )

  if manifest.isDirectory:
    self.name = manifest.name
    self.entries = manifest.entries

  self

func new*(T: type Manifest, manifest: Manifest): Manifest =
  ## Create an unprotected dataset from an
  ## erasure protected one
  ##

  var self = Manifest(
    treeCid: manifest.originalTreeCid,
    datasetSize: manifest.originalDatasetSize,
    version: manifest.version,
    codec: manifest.codec,
    hcodec: manifest.hcodec,
    blockSize: manifest.blockSize,
    protected: false,
    path: manifest.path,
    mimetype: manifest.mimetype,
    isDirectory: manifest.isDirectory,
  )

  if manifest.isDirectory:
    self.name = manifest.name
    self.entries = manifest.entries

  self

func new*(
    T: type Manifest,
    treeCid: Cid,
    datasetSize: NBytes,
    blockSize: NBytes,
    version: CidVersion,
    hcodec: MultiCodec,
    codec: MultiCodec,
    ecK: int,
    ecM: int,
    originalTreeCid: Cid,
    originalDatasetSize: NBytes,
    strategy = SteppedStrategy,
    path: ?string = string.none,
    mimetype: ?string = string.none,
): Manifest =
  ## Create a protected file manifest (non-directory)
  Manifest(
    treeCid: treeCid,
    datasetSize: datasetSize,
    blockSize: blockSize,
    version: version,
    hcodec: hcodec,
    codec: codec,
    protected: true,
    ecK: ecK,
    ecM: ecM,
    originalTreeCid: originalTreeCid,
    originalDatasetSize: originalDatasetSize,
    protectedStrategy: strategy,
    path: path,
    mimetype: mimetype,
    isDirectory: false,
  )

func new*(
    T: type Manifest,
    treeCid: Cid,
    datasetSize: NBytes,
    blockSize: NBytes,
    version: CidVersion,
    hcodec: MultiCodec,
    codec: MultiCodec,
    ecK: int,
    ecM: int,
    originalTreeCid: Cid,
    originalDatasetSize: NBytes,
    name: string,
    entries: OrderedTable[string, Cid],
    strategy = SteppedStrategy,
    path: ?string = string.none,
    mimetype: ?string = string.none,
): Manifest =
  ## Create a protected directory manifest
  Manifest(
    treeCid: treeCid,
    datasetSize: datasetSize,
    blockSize: blockSize,
    version: version,
    hcodec: hcodec,
    codec: codec,
    protected: true,
    ecK: ecK,
    ecM: ecM,
    originalTreeCid: originalTreeCid,
    originalDatasetSize: originalDatasetSize,
    protectedStrategy: strategy,
    path: path,
    mimetype: mimetype,
    isDirectory: true,
    name: name,
    entries: entries,
  )

func new*(
    T: type Manifest,
    manifest: Manifest,
    verifyRoot: Cid,
    slotRoots: openArray[Cid],
    cellSize = DefaultCellSize,
    strategy = LinearStrategy,
): ?!Manifest =
  ## Create a verifiable dataset from an
  ## protected one
  ##

  if not manifest.protected:
    return failure newException(
      ArchivistError, "Can create verifiable manifest only from protected manifest."
    )

  if slotRoots.len != manifest.numSlots:
    return failure newException(ArchivistError, "Wrong number of slot roots.")

  var self = Manifest(
    treeCid: manifest.treeCid,
    datasetSize: manifest.datasetSize,
    version: manifest.version,
    codec: manifest.codec,
    hcodec: manifest.hcodec,
    blockSize: manifest.blockSize,
    protected: true,
    ecK: manifest.ecK,
    ecM: manifest.ecM,
    originalTreeCid: manifest.originalTreeCid,
    originalDatasetSize: manifest.originalDatasetSize,
    protectedStrategy: manifest.protectedStrategy,
    verifiable: true,
    verifyRoot: verifyRoot,
    slotRoots: @slotRoots,
    cellSize: cellSize,
    verifiableStrategy: strategy,
    path: manifest.path,
    mimetype: manifest.mimetype,
    isDirectory: manifest.isDirectory,
  )

  if manifest.isDirectory:
    self.name = manifest.name
    self.entries = manifest.entries

  success self

func new*(
    T: type Manifest,
    treeCid: Cid,
    blockSize: NBytes,
    datasetSize: NBytes,
    name: string,
    entries: OrderedTable[string, Cid],
    version: CidVersion = CIDv1,
    hcodec = Sha256HashCodec,
    codec = BlockCodec,
): Manifest =
  ## Create a new directory manifest
  T(
    treeCid: treeCid,
    blockSize: blockSize,
    datasetSize: datasetSize,
    version: version,
    codec: codec,
    hcodec: hcodec,
    protected: false,
    path: string.none,
    mimetype: string.none,
    isDirectory: true,
    name: name,
    entries: entries,
  )

func new*(T: type Manifest, data: openArray[byte]): ?!Manifest =
  ## Create a manifest instance from given data
  ##

  Manifest.decode(data)
