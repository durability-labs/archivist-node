## Copyright (c) 2025 Archivist Authors
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## Directory operations for ArchivistNode
##
## This module is kept separate from node.nim to avoid importing minprotobuf
## into the main compilation path, which triggers serialization conflicts
## with TOML config loading.

{.push raises: [].}

import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/libp2p/cid

# Import minprotobuf explicitly to avoid leaking symbols that conflict with serialization
from pkg/libp2p/protobuf/minprotobuf import
  ProtoBuffer, initProtoBuffer, getField, getRequiredRepeatedField,
  write, finish, ProtoResult

import ./manifest/directory
import ./blocktype as bt
import ./stores
import ./archivisttypes
import ./units
import ./errors
import ./logutils

logScope:
  topics = "archivist directorynode"

proc decodeDirectoryManifest*(blk: bt.Block): ?!DirectoryManifest =
  ## Decode a directory manifest from a block
  ##
  if not ?blk.cid.isDirectory:
    return failure "Cid not a directory codec"

  var
    pbNode = initProtoBuffer(blk.data)
    pbEntries: seq[seq[byte]]
    totalSize: uint64
    name: string
    entries: seq[DirectoryEntry]

  if pbNode.getRequiredRepeatedField(1, pbEntries).isErr:
    return failure("Unable to decode `entries` from directory manifest!")

  if pbNode.getField(2, totalSize).isErr:
    return failure("Unable to decode `totalSize` from directory manifest!")

  if pbNode.getField(3, name).isErr:
    return failure("Unable to decode `name` from directory manifest!")

  for pbEntryData in pbEntries:
    var
      pbEntry = initProtoBuffer(pbEntryData)
      entryName: string
      cidBuf: seq[byte]
      size: uint64
      isDir: uint32
      mimetype: string

    if pbEntry.getField(1, entryName).isErr:
      return failure("Unable to decode entry `name` from directory manifest!")

    if pbEntry.getField(2, cidBuf).isErr:
      return failure("Unable to decode entry `cid` from directory manifest!")

    if pbEntry.getField(3, size).isErr:
      return failure("Unable to decode entry `size` from directory manifest!")

    if pbEntry.getField(4, isDir).isErr:
      return failure("Unable to decode entry `isDirectory` from directory manifest!")

    if pbEntry.getField(5, mimetype).isErr:
      return failure("Unable to decode entry `mimetype` from directory manifest!")

    let entryCid = ?Cid.init(cidBuf).mapFailure

    entries.add(DirectoryEntry(
      name: entryName,
      cid: entryCid,
      size: size.NBytes,
      isDirectory: isDir != 0,
      mimetype: mimetype,
    ))

  success DirectoryManifest(
    entries: entries,
    totalSize: totalSize.NBytes,
    name: name,
  )

proc encodeDirectoryManifest*(directory: DirectoryManifest): seq[byte] =
  ## Encode a directory manifest to protobuf bytes
  ##
  var pbNode = initProtoBuffer()

  for entry in directory.entries:
    var pbEntry = initProtoBuffer()
    pbEntry.write(1, entry.name)
    pbEntry.write(2, entry.cid.data.buffer)
    pbEntry.write(3, entry.size.uint64)
    pbEntry.write(4, entry.isDirectory.uint32)
    if entry.mimetype.len > 0:
      pbEntry.write(5, entry.mimetype)
    pbEntry.finish()
    pbNode.write(1, pbEntry)

  pbNode.write(2, directory.totalSize.uint64)

  if directory.name.len > 0:
    pbNode.write(3, directory.name)

  pbNode.finish()
  pbNode.buffer

proc storeDirectoryManifest*(
    networkStore: NetworkStore, directory: DirectoryManifest
): Future[?!bt.Block] {.async: (raises: [CancelledError]).} =
  ## Store a directory manifest and return its block
  ##
  let encoded = encodeDirectoryManifest(directory)

  without blk =? bt.Block.new(data = encoded, codec = DirectoryCodec), error:
    trace "Unable to create block from directory manifest"
    return failure(error)

  if err =? (await networkStore.putBlock(blk)).errorOption:
    trace "Unable to store directory manifest block", cid = blk.cid, err = err.msg
    return failure(err)

  info "Stored directory manifest",
    cid = blk.cid,
    entries = directory.entries.len,
    totalSize = directory.totalSize

  success blk

proc fetchDirectoryManifest*(
    networkStore: NetworkStore, cid: Cid
): Future[?!DirectoryManifest] {.async: (raises: [CancelledError]).} =
  ## Fetch and decode a directory manifest block
  ##
  if err =? cid.isDirectory.errorOption:
    return failure "CID has invalid content type for directory manifest {$cid}"

  trace "Retrieving directory manifest for cid", cid

  without blk =? await networkStore.getBlock(BlockAddress.init(cid)), err:
    trace "Error retrieving directory manifest block", cid, err = err.msg
    return failure err

  trace "Decoding directory manifest for cid", cid

  without directory =? decodeDirectoryManifest(blk), err:
    trace "Unable to decode as directory manifest", err = err.msg
    return failure("Unable to decode as directory manifest")

  trace "Decoded directory manifest", cid, entries = directory.entries.len

  return directory.success
