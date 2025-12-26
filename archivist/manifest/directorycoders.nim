## Copyright (c) 2025 Archivist Authors
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# This module implements serialization and deserialization of DirectoryManifest
# It is kept separate from coders.nim to avoid pulling directory types into
# the main compilation path which triggers serialization errors with ref types.

{.push raises: [].}

# Use specific libp2p imports instead of the full package
# to avoid serialization conflicts
import pkg/libp2p/cid
import pkg/libp2p/protobuf/minprotobuf
import pkg/questionable/results

import ./directory
import ../errors
import ../blocktype
import ../units

proc encode*(self: DirectoryManifest): ?!seq[byte] =
  ## Encode the directory manifest into a ``DirectoryCodec``
  ## multicodec container
  ##
  ## ```protobuf
  ## Message DirectoryEntry {
  ##   string name = 1;
  ##   bytes cid = 2;
  ##   uint64 size = 3;
  ##   bool isDirectory = 4;
  ##   optional string mimetype = 5;
  ## }
  ##
  ## Message DirectoryManifest {
  ##   repeated DirectoryEntry entries = 1;
  ##   uint64 totalSize = 2;
  ##   optional string name = 3;
  ## }
  ## ```

  var pbNode = initProtoBuffer()

  for entry in self.entries:
    var pbEntry = initProtoBuffer()
    pbEntry.write(1, entry.name)
    pbEntry.write(2, entry.cid.data.buffer)
    pbEntry.write(3, entry.size.uint64)
    pbEntry.write(4, entry.isDirectory.uint32)
    if entry.mimetype.len > 0:
      pbEntry.write(5, entry.mimetype)
    pbEntry.finish()
    pbNode.write(1, pbEntry)

  pbNode.write(2, self.totalSize.uint64)

  if self.name.len > 0:
    pbNode.write(3, self.name)

  pbNode.finish()
  return pbNode.buffer.success

proc decode*(_: type DirectoryManifest, data: openArray[byte]): ?!DirectoryManifest =
  ## Decode a directory manifest from a data blob
  ##

  var
    pbNode = initProtoBuffer(data)
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

    let cid = ?Cid.init(cidBuf).mapFailure

    entries.add(DirectoryEntry(
      name: entryName,
      cid: cid,
      size: size.NBytes,
      isDirectory: isDir != 0,
      mimetype: mimetype,  # Empty string = not set
    ))

  success DirectoryManifest(
    entries: entries,
    totalSize: totalSize.NBytes,
    name: name,  # Empty string = not set
  )

func decode*(_: type DirectoryManifest, blk: Block): ?!DirectoryManifest =
  ## Decode a directory manifest from a block
  ##

  if not ?blk.cid.isDirectory:
    return failure "Cid not a directory codec"

  DirectoryManifest.decode(blk.data)
