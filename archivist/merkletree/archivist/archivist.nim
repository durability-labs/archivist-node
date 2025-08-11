## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/bitops
import std/sequtils

import pkg/questionable
import pkg/questionable/results
import pkg/libp2p/[cid, multicodec, multihash]
import pkg/constantine/hashes
import ../../utils
import ../../rng
import ../../errors
import ../../blocktype

from ../../utils/digest import digestBytes

import ../merkletree

export merkletree

logScope:
  topics = "archivist merkletree"

type
  ByteTreeKey* {.pure.} = enum
    KeyNone = 0x0.byte
    KeyBottomLayer = 0x1.byte
    KeyOdd = 0x2.byte
    KeyOddAndBottomLayer = 0x3.byte

  ByteHash* = seq[byte]
  ByteTree* = MerkleTree[ByteHash, ByteTreeKey]
  ByteProof* = MerkleProof[ByteHash, ByteTreeKey]

  ArchivistTree* = ref object of ByteTree
    mcodec*: MultiCodec

  ArchivistProof* = ref object of ByteProof
    mcodec*: MultiCodec

# CodeHashes is not exported from libp2p
# So we need to recreate it instead of 
proc initMultiHashCodeTable(): Table[MultiCodec, MHash] {.compileTime.} =
  for item in HashesList:
    result[item.mcodec] = item

const CodeHashes = initMultiHashCodeTable()

func mhash*(mcodec: MultiCodec): ?!MHash =
  let mhash = CodeHashes.getOrDefault(mcodec)

  if isNil(mhash.coder):
    return failure "Invalid multihash codec"

  success mhash

func digestSize*(self: (ArchivistTree or ArchivistProof)): int =
  ## Number of leaves
  ##

  self.mhash.size

func getProof*(self: ArchivistTree, index: int): ?!ArchivistProof =
  var proof = ArchivistProof(mcodec: self.mcodec)

  ?self.getProof(index, proof)

  success proof

func verify*(self: ArchivistProof, leaf: MultiHash, root: MultiHash): ?!bool =
  ## Verify hash
  ##

  let
    rootBytes = root.digestBytes
    leafBytes = leaf.digestBytes

  if self.mcodec != root.mcodec or self.mcodec != leaf.mcodec:
    return failure "Hash codec mismatch"

  if rootBytes.len != root.size and leafBytes.len != leaf.size:
    return failure "Invalid hash length"

  self.verify(leafBytes, rootBytes)

func verify*(self: ArchivistProof, leaf: Cid, root: Cid): ?!bool =
  self.verify(?leaf.mhash.mapFailure, ?leaf.mhash.mapFailure)

proc rootCid*(
    self: ArchivistTree, version = CIDv1, dataCodec = DatasetRootCodec
): ?!Cid =
  if (?self.root).len == 0:
    return failure "Empty root"

  let mhash = ?MultiHash.init(self.mcodec, ?self.root).mapFailure

  Cid.init(version, DatasetRootCodec, mhash).mapFailure

func getLeafCid*(
    self: ArchivistTree, i: Natural, version = CIDv1, dataCodec = BlockCodec
): ?!Cid =
  if i >= self.leavesCount:
    return failure "Invalid leaf index " & $i

  let
    leaf = self.leaves[i]
    mhash = ?MultiHash.init($self.mcodec, leaf).mapFailure

  Cid.init(version, dataCodec, mhash).mapFailure

proc `$`*(self: ArchivistTree): string =
  let root =
    if self.root.isOk:
      byteutils.toHex(self.root.get)
    else:
      "none"
  "ArchivistTree(" & " root: " & root & ", leavesCount: " & $self.leavesCount &
    ", levels: " & $self.levels & ", mcodec: " & $self.mcodec & " )"

proc `$`*(self: ArchivistProof): string =
  "ArchivistProof(" & " nleaves: " & $self.nleaves & ", index: " & $self.index &
    ", path: " & $self.path.mapIt(byteutils.toHex(it)) & ", mcodec: " & $self.mcodec &
    " )"

func compress*(x, y: openArray[byte], key: ByteTreeKey, mhash: MHash): ?!ByteHash =
  ## Compress two hashes
  ##

  # Using Constantine's SHA256 instead of mhash for optimal performance on 32-byte merkle node hashing
  # See: https://github.com/codex-storage/nim-codex/issues/1162

  let input = @x & @y & @[key.byte]
  var digest = hashes.sha256.hash(input)

  success @digest

func init*(
    _: type ArchivistTree,
    mcodec: MultiCodec = Sha256HashCodec,
    leaves: openArray[ByteHash],
): ?!ArchivistTree =
  if leaves.len == 0:
    return failure "Empty leaves"

  let
    mhash = ?mcodec.mhash()
    compressor = proc(x, y: seq[byte], key: ByteTreeKey): ?!ByteHash {.noSideEffect.} =
      compress(x, y, key, mhash)
    Zero: ByteHash = newSeq[byte](mhash.size)

  if mhash.size != leaves[0].len:
    return failure "Invalid hash length"

  var self = ArchivistTree(mcodec: mcodec, compress: compressor, zero: Zero)

  self.layers = ?merkleTreeWorker(self, leaves, isBottomLayer = true)
  success self

func init*(_: type ArchivistTree, leaves: openArray[MultiHash]): ?!ArchivistTree =
  if leaves.len == 0:
    return failure "Empty leaves"

  let
    mcodec = leaves[0].mcodec
    leaves = leaves.mapIt(it.digestBytes)

  ArchivistTree.init(mcodec, leaves)

func init*(_: type ArchivistTree, leaves: openArray[Cid]): ?!ArchivistTree =
  if leaves.len == 0:
    return failure "Empty leaves"

  let
    mcodec = (?leaves[0].mhash.mapFailure).mcodec
    leaves = leaves.mapIt((?it.mhash.mapFailure).digestBytes)

  ArchivistTree.init(mcodec, leaves)

proc fromNodes*(
    _: type ArchivistTree,
    mcodec: MultiCodec = Sha256HashCodec,
    nodes: openArray[ByteHash],
    nleaves: int,
): ?!ArchivistTree =
  if nodes.len == 0:
    return failure "Empty nodes"

  let
    mhash = ?mcodec.mhash()
    Zero = newSeq[byte](mhash.size)
    compressor = proc(x, y: seq[byte], key: ByteTreeKey): ?!ByteHash {.noSideEffect.} =
      compress(x, y, key, mhash)

  if mhash.size != nodes[0].len:
    return failure "Invalid hash length"

  var
    self = ArchivistTree(compress: compressor, zero: Zero, mcodec: mcodec)
    layer = nleaves
    pos = 0

  while pos < nodes.len:
    self.layers.add(nodes[pos ..< (pos + layer)])
    pos += layer
    layer = divUp(layer, 2)

  let
    index = Rng.instance.rand(nleaves - 1)
    proof = ?self.getProof(index)

  if not ?proof.verify(self.leaves[index], ?self.root): # sanity check
    return failure "Unable to verify tree built from nodes"

  success self

func init*(
    _: type ArchivistProof,
    mcodec: MultiCodec = Sha256HashCodec,
    index: int,
    nleaves: int,
    nodes: openArray[ByteHash],
): ?!ArchivistProof =
  if nodes.len == 0:
    return failure "Empty nodes"

  let
    mhash = ?mcodec.mhash()
    Zero = newSeq[byte](mhash.size)
    compressor = proc(x, y: seq[byte], key: ByteTreeKey): ?!seq[byte] {.noSideEffect.} =
      compress(x, y, key, mhash)

  success ArchivistProof(
    compress: compressor,
    zero: Zero,
    mcodec: mcodec,
    index: index,
    nleaves: nleaves,
    path: @nodes,
  )
