## Copyright (c) 2025 Archivist Authors
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# This module defines DirectoryManifest for folder/directory support

{.push raises: [].}

# Note: minprotobuf import is NOT included here - it triggers a serialization
# error when imported into a module that gets pulled into TOML config loading.
# The encode/decode procs that need protobuf are in coders.nim instead.

import pkg/libp2p/[cid, multihash, multicodec]
import pkg/questionable/results

import ../errors
import ../units
import ../archivisttypes

type
  DirectoryEntry* = object
    name*: string
    cid*: Cid
    size*: NBytes
    isDirectory*: bool
    mimetype*: string  # Empty string = not set

  DirectoryManifest* = object
    entries*: seq[DirectoryEntry]
    totalSize*: NBytes
    name*: string  # Empty string = not set

############################################################
# Accessors
############################################################

func entries*(self: DirectoryManifest): seq[DirectoryEntry] =
  self.entries

func totalSize*(self: DirectoryManifest): NBytes =
  self.totalSize

func name*(self: DirectoryManifest): string =
  self.name

func filesCount*(self: DirectoryManifest): int =
  var count = 0
  for entry in self.entries:
    if not entry.isDirectory:
      inc count
  count

func dirsCount*(self: DirectoryManifest): int =
  var count = 0
  for entry in self.entries:
    if entry.isDirectory:
      inc count
  count

############################################################
# Predicates
############################################################

func isDirectory*(cid: Cid): ?!bool =
  success (DirectoryCodec == ?cid.contentType().mapFailure(ArchivistError))

func isDirectory*(mc: MultiCodec): ?!bool =
  success mc == DirectoryCodec

## Note: encode/decode procs are in coders.nim to avoid minprotobuf import
## which triggers a serialization error when imported here.

############################################################
# Constructors
############################################################

func new*(
    T: type DirectoryManifest,
    entries: seq[DirectoryEntry] = @[],
    name: string = "",
): DirectoryManifest =
  var total: NBytes = 0.NBytes
  for entry in entries:
    total = NBytes(total.int + entry.size.int)

  T(
    entries: entries,
    totalSize: total,
    name: name,
  )

func new*(
    T: type DirectoryEntry,
    name: string,
    cid: Cid,
    size: NBytes,
    isDirectory: bool = false,
    mimetype: string = "",
): DirectoryEntry =
  T(
    name: name,
    cid: cid,
    size: size,
    isDirectory: isDirectory,
    mimetype: mimetype,
  )

############################################################
# String representation
############################################################

func `$`*(entry: DirectoryEntry): string =
  result = "DirectoryEntry(name: " & entry.name
  result &= ", cid: " & $entry.cid
  result &= ", size: " & $entry.size
  result &= ", isDirectory: " & $entry.isDirectory
  if entry.mimetype.len > 0:
    result &= ", mimetype: " & entry.mimetype
  result &= ")"

func `$`*(self: DirectoryManifest): string =
  result = "DirectoryManifest("
  if self.name.len > 0:
    result &= "name: " & self.name & ", "
  result &= "totalSize: " & $self.totalSize
  result &= ", entries: " & $self.entries.len & " items)"

############################################################
# Equality
############################################################

func `==`*(a, b: DirectoryEntry): bool =
  a.name == b.name and
  a.cid == b.cid and
  a.size == b.size and
  a.isDirectory == b.isDirectory and
  a.mimetype == b.mimetype

func `==`*(a, b: DirectoryManifest): bool =
  a.entries == b.entries and
  a.totalSize == b.totalSize and
  a.name == b.name

############################################################
# Helpers
############################################################

proc findEntry*(self: DirectoryManifest, name: string, foundEntry: var DirectoryEntry): bool =
  ## Find an entry by name in the directory
  ## Sets foundEntry and returns true if found, returns false otherwise
  for entry in self.entries:
    if entry.name == name:
      foundEntry = entry
      return true
  return false

proc sortByName(entries: var seq[DirectoryEntry]) =
  ## Simple insertion sort to avoid importing std/algorithm which triggers
  ## a serialization error during TOML config loading
  for i in 1 ..< entries.len:
    let key = entries[i]
    var j = i - 1
    while j >= 0 and entries[j].name > key.name:
      entries[j + 1] = entries[j]
      dec j
    entries[j + 1] = key

proc sortedEntries*(self: DirectoryManifest): seq[DirectoryEntry] =
  ## Return entries sorted: directories first, then files, alphabetically
  var dirs: seq[DirectoryEntry]
  var files: seq[DirectoryEntry]

  for entry in self.entries:
    if entry.isDirectory:
      dirs.add(entry)
    else:
      files.add(entry)

  sortByName(dirs)
  sortByName(files)

  result = dirs & files
