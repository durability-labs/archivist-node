import std/sequtils

import pkg/unittest2
import pkg/questionable/results
import pkg/stew/byteutils
import pkg/libp2p

import pkg/archivist/archivisttypes
import pkg/archivist/merkletree
import pkg/archivist/utils/digest

import ./helpers
import ./generictreetests

# TODO: Generalize to other hashes

const
  data = [
    "00000000000000000000000000000001".toBytes,
    "00000000000000000000000000000002".toBytes,
    "00000000000000000000000000000003".toBytes,
    "00000000000000000000000000000004".toBytes,
    "00000000000000000000000000000005".toBytes,
    "00000000000000000000000000000006".toBytes,
    "00000000000000000000000000000007".toBytes,
    "00000000000000000000000000000008".toBytes,
    "00000000000000000000000000000009".toBytes,
    "00000000000000000000000000000010".toBytes,
  ]
  sha256 = Sha256HashCodec

suite "Test ArchivistTree":
  test "Cannot init tree without any multihash leaves":
    check:
      ArchivistTree.init(leaves = newSeq[MultiHash]()).isErr

  test "Cannot init tree without any cid leaves":
    check:
      ArchivistTree.init(leaves = newSeq[Cid]()).isErr

  test "Cannot init tree without any byte leaves":
    check:
      ArchivistTree.init(sha256, leaves = newSeq[ByteHash]()).isErr

  test "Should build tree from multihash leaves":
    var expectedLeaves = data.mapIt(MultiHash.digest($sha256, it).tryGet())

    var tree = ArchivistTree.init(leaves = expectedLeaves)
    check:
      tree.isOk
      tree.get().leaves == expectedLeaves.mapIt(it.digestBytes)
      tree.get().mcodec == sha256

  test "Should build tree from cid leaves":
    var expectedLeaves = data.mapIt(
      Cid.init(CidVersion.CIDv1, BlockCodec, MultiHash.digest($sha256, it).tryGet).tryGet
    )

    let tree = ArchivistTree.init(leaves = expectedLeaves)

    check:
      tree.isOk
      tree.get().leaves == expectedLeaves.mapIt(it.mhash.tryGet.digestBytes)
      tree.get().mcodec == sha256

  test "Should build from raw digestbytes (should not hash leaves)":
    let tree = ArchivistTree.init(sha256, leaves = data).tryGet

    check:
      tree.mcodec == sha256
      tree.leaves == data

  test "Should build from nodes":
    let
      tree = ArchivistTree.init(sha256, leaves = data).tryGet
      fromNodes =
        ArchivistTree.fromNodes(nodes = toSeq(tree.nodes), nleaves = tree.leavesCount).tryGet

    check:
      tree.mcodec == sha256
      tree == fromNodes

let
  mhash = sha256.mhash().tryGet
  zero: seq[byte] = newSeq[byte](mhash.size)
  compress = proc(x, y: seq[byte], key: ByteTreeKey): seq[byte] =
    compress(x, y, key, mhash).tryGet

  makeTree = proc(data: seq[seq[byte]]): ArchivistTree =
    ArchivistTree.init(sha256, leaves = data).tryGet

testGenericTree("ArchivistTree", @data, zero, compress, makeTree)
