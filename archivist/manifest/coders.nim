## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# This module implements serialization and deserialization of Manifest

{.push raises: [].}

import times
import std/tables
import std/sequtils

import pkg/libp2p
import pkg/questionable
import pkg/questionable/results
import pkg/chronos

import ./manifest
import ../errors
import ../blocktype
import ../logutils
import ../indexingstrategy

proc encode*(manifest: Manifest): ?!seq[byte] =
  ## Encode the manifest into a ``ManifestCodec``
  ## multicodec container (Dag-pb) for now
  ##

  ?manifest.verify()
  var pbNode = initProtoBuffer()

  # NOTE: The `Data` field in the the `dag-pb`
  # contains the following protobuf `Message`
  #
  # ```protobuf
  #   Message VerificationInfo {
  #     bytes verifyRoot = 1;             # Decimal encoded field-element
  #     repeated bytes slotRoots = 2;     # Decimal encoded field-elements
  #   }
  #   Message ErasureInfo {
  #     optional uint32 ecK = 1;                            # number of encoded blocks
  #     optional uint32 ecM = 2;                            # number of parity blocks
  #     optional bytes originalTreeCid = 3;                 # cid of the original dataset
  #     optional uint32 originalDatasetSize = 4;            # size of the original dataset
  #     optional VerificationInformation verification = 5;  # verification information
  #   }
  #
  #   Message DirectoryEntry {
  #     string path = 1;                  # File path within directory
  #     bytes cid = 2;                    # Manifest CID for the file
  #   }
  #
  #   Message Header {
  #     optional bytes treeCid = 1;       # cid (root) of the tree
  #     optional uint32 blockSize = 2;    # size of a single block
  #     optional uint64 datasetSize = 3;  # size of the dataset
  #     optional codec: MultiCodec = 4;   # Dataset codec
  #     optional hcodec: MultiCodec = 5   # Multihash codec
  #     optional version: CidVersion = 6; # Cid version
  #     optional ErasureInfo erasure = 7; # erasure coding info
  #     optional path: ?string = 8;       # virtual path within directory
  #     optional mimetype: ?string = 9;   # original mimetype
  #     optional name: string = 10;       # directory name (if isDirectory)
  #     repeated DirectoryEntry entries = 11; # directory entries (if isDirectory)
  #   }
  # ```
  #
  # var treeRootVBuf = initVBuffer()
  var header = initProtoBuffer()
  header.write(1, manifest.treeCid.data.buffer)
  header.write(2, manifest.blockSize.uint32)
  header.write(3, manifest.datasetSize.uint64)
  header.write(4, manifest.codec.uint32)
  header.write(5, manifest.hcodec.uint32)
  header.write(6, manifest.version.uint32)

  if manifest.protected:
    var erasureInfo = initProtoBuffer()
    erasureInfo.write(1, manifest.ecK.uint32)
    erasureInfo.write(2, manifest.ecM.uint32)
    erasureInfo.write(3, manifest.originalTreeCid.data.buffer)
    erasureInfo.write(4, manifest.originalDatasetSize.uint64)
    erasureInfo.write(5, manifest.protectedStrategy.uint32)

    if manifest.verifiable:
      var verificationInfo = initProtoBuffer()
      verificationInfo.write(1, manifest.verifyRoot.data.buffer)
      for slotRoot in manifest.slotRoots:
        verificationInfo.write(2, slotRoot.data.buffer)
      verificationInfo.write(3, manifest.cellSize.uint32)
      verificationInfo.write(4, manifest.verifiableStrategy.uint32)
      erasureInfo.write(6, verificationInfo)

    erasureInfo.finish()
    header.write(7, erasureInfo)

  if manifest.path.isSome:
    header.write(8, manifest.path.get())

  if manifest.mimetype.isSome:
    header.write(9, manifest.mimetype.get())

  # Directory-specific fields
  if manifest.isDirectory:
    header.write(10, manifest.name)
    for path, cid in manifest.entries.pairs:
      var entryBuf = initProtoBuffer()
      entryBuf.write(1, path)
      entryBuf.write(2, cid.data.buffer)
      entryBuf.finish()
      header.write(11, entryBuf)

  pbNode.write(1, header) # set the treeCid as the data field
  pbNode.finish()

  return pbNode.buffer.success

proc decode*(_: type Manifest, data: openArray[byte]): ?!Manifest =
  ## Decode a manifest from a data blob
  ##

  var
    pbNode = initProtoBuffer(data)
    pbHeader: ProtoBuffer
    pbErasureInfo: ProtoBuffer
    pbVerificationInfo: ProtoBuffer
    treeCidBuf: seq[byte]
    originalTreeCid: seq[byte]
    datasetSize: uint64
    codec: uint32
    hcodec: uint32
    version: uint32
    blockSize: uint32
    originalDatasetSize: uint64
    ecK, ecM: uint32
    protectedStrategy: uint32
    verifyRoot: seq[byte]
    slotRoots: seq[seq[byte]]
    cellSize: uint32
    verifiableStrategy: uint32
    path: string
    mimetype: string
    directoryName: string
    entryBuffers: seq[seq[byte]]

  # Decode `Header` message
  if pbNode.getField(1, pbHeader).isErr:
    return failure("Unable to decode `Header` from dag-pb manifest!")

  # Decode `Header` contents
  if pbHeader.getField(1, treeCidBuf).isErr:
    return failure("Unable to decode `treeCid` from manifest!")

  if pbHeader.getField(2, blockSize).isErr:
    return failure("Unable to decode `blockSize` from manifest!")

  if pbHeader.getField(3, datasetSize).isErr:
    return failure("Unable to decode `datasetSize` from manifest!")

  if pbHeader.getField(4, codec).isErr:
    return failure("Unable to decode `codec` from manifest!")

  if pbHeader.getField(5, hcodec).isErr:
    return failure("Unable to decode `hcodec` from manifest!")

  if pbHeader.getField(6, version).isErr:
    return failure("Unable to decode `version` from manifest!")

  if pbHeader.getField(7, pbErasureInfo).isErr:
    return failure("Unable to decode `erasureInfo` from manifest!")

  if pbHeader.getField(8, path).isErr:
    return failure("Unable to decode `path` from manifest!")

  if pbHeader.getField(9, mimetype).isErr:
    return failure("Unable to decode `mimetype` from manifest!")

  # Directory-specific fields
  if pbHeader.getField(10, directoryName).isErr:
    return failure("Unable to decode `name` from manifest!")

  if pbHeader.getRepeatedField(11, entryBuffers).isErr:
    return failure("Unable to decode `entries` from manifest!")

  let protected = pbErasureInfo.buffer.len > 0
  var verifiable = false
  if protected:
    if pbErasureInfo.getField(1, ecK).isErr:
      return failure("Unable to decode `K` from manifest!")

    if pbErasureInfo.getField(2, ecM).isErr:
      return failure("Unable to decode `M` from manifest!")

    if pbErasureInfo.getField(3, originalTreeCid).isErr:
      return failure("Unable to decode `originalTreeCid` from manifest!")

    if pbErasureInfo.getField(4, originalDatasetSize).isErr:
      return failure("Unable to decode `originalDatasetSize` from manifest!")

    if pbErasureInfo.getField(5, protectedStrategy).isErr:
      return failure("Unable to decode `protectedStrategy` from manifest!")

    if pbErasureInfo.getField(6, pbVerificationInfo).isErr:
      return failure("Unable to decode `verificationInfo` from manifest!")

    verifiable = pbVerificationInfo.buffer.len > 0
    if verifiable:
      if pbVerificationInfo.getField(1, verifyRoot).isErr:
        return failure("Unable to decode `verifyRoot` from manifest!")

      if pbVerificationInfo.getRequiredRepeatedField(2, slotRoots).isErr:
        return failure("Unable to decode `slotRoots` from manifest!")

      if pbVerificationInfo.getField(3, cellSize).isErr:
        return failure("Unable to decode `cellSize` from manifest!")

      if pbVerificationInfo.getField(4, verifiableStrategy).isErr:
        return failure("Unable to decode `verifiableStrategy` from manifest!")

  let treeCid = ?Cid.init(treeCidBuf).mapFailure

  var pathOption = if path.len == 0: string.none else: path.some
  var mimetypeOption = if mimetype.len == 0: string.none else: mimetype.some

  # Check if this is a directory manifest (has entries or directoryName)
  let isDirectory = entryBuffers.len > 0 or directoryName.len > 0

  # Parse directory entries
  var entries: OrderedTable[string, Cid]
  if isDirectory:
    for entryBuf in entryBuffers:
      var
        pbEntry = initProtoBuffer(entryBuf)
        entryPath: string
        entryCidBuf: seq[byte]

      if pbEntry.getField(1, entryPath).isErr:
        return failure("Unable to decode entry path from manifest!")

      if pbEntry.getField(2, entryCidBuf).isErr:
        return failure("Unable to decode entry CID from manifest!")

      let entryCid = ?Cid.init(entryCidBuf).mapFailure
      entries[entryPath] = entryCid

  let self =
    if isDirectory and protected:
      let origTreeCid = ?Cid.init(originalTreeCid).mapFailure
      Manifest.new(
        treeCid = treeCid,
        datasetSize = datasetSize.NBytes,
        blockSize = blockSize.NBytes,
        version = CidVersion(version),
        hcodec = hcodec.MultiCodec,
        codec = codec.MultiCodec,
        ecK = ecK.int,
        ecM = ecM.int,
        originalTreeCid = origTreeCid,
        originalDatasetSize = originalDatasetSize.NBytes,
        strategy = StrategyType(protectedStrategy),
        path = pathOption,
        mimetype = mimetypeOption,
        name = directoryName,
        entries = entries,
      )
    elif isDirectory:
      Manifest.new(
        treeCid = treeCid,
        datasetSize = datasetSize.NBytes,
        blockSize = blockSize.NBytes,
        name = directoryName,
        entries = entries,
        version = CidVersion(version),
        hcodec = hcodec.MultiCodec,
        codec = codec.MultiCodec,
      )
    elif protected:
      let origTreeCid = ?Cid.init(originalTreeCid).mapFailure
      Manifest.new(
        treeCid = treeCid,
        datasetSize = datasetSize.NBytes,
        blockSize = blockSize.NBytes,
        version = CidVersion(version),
        hcodec = hcodec.MultiCodec,
        codec = codec.MultiCodec,
        ecK = ecK.int,
        ecM = ecM.int,
        originalTreeCid = origTreeCid,
        originalDatasetSize = originalDatasetSize.NBytes,
        strategy = StrategyType(protectedStrategy),
        path = pathOption,
        mimetype = mimetypeOption,
      )
    else:
      Manifest.new(
        treeCid = treeCid,
        datasetSize = datasetSize.NBytes,
        blockSize = blockSize.NBytes,
        version = CidVersion(version),
        hcodec = hcodec.MultiCodec,
        codec = codec.MultiCodec,
        path = pathOption,
        mimetype = mimetypeOption,
      )

  ?self.verify()

  if verifiable:
    let
      verifyRootCid = ?Cid.init(verifyRoot).mapFailure
      slotRootCids = slotRoots.mapIt(?Cid.init(it).mapFailure)

    return Manifest.new(
      manifest = self,
      verifyRoot = verifyRootCid,
      slotRoots = slotRootCids,
      cellSize = cellSize.NBytes,
      strategy = StrategyType(verifiableStrategy),
    )

  self.success

func decode*(_: type Manifest, blk: Block): ?!Manifest =
  ## Decode a manifest using `decoder`
  ##

  if not ?blk.cid.isManifest:
    return failure "Cid not a manifest codec"

  Manifest.decode(blk.data)
