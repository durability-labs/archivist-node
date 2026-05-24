import std/sequtils

import pkg/unittest2
import pkg/libp2p
import pkg/questionable/results

import pkg/archivist/archivisttypes
import pkg/archivist/merkletree

const sha256 = Sha256HashCodec

func expectedWidths(nleaves: int): seq[int] =
  var
    width = nleaves
    widths: seq[int]

  widths.add(width)
  while true:
    width = (width + 1) div 2
    widths.add(width)
    if width == 1:
      break

  widths

func expectedTotal(widths: openArray[int]): int =
  var total = 0
  for width in widths:
    total += width
  total

func makeLeaves(nleaves: int): seq[ByteHash] =
  var leaves: seq[ByteHash]
  for i in 0 ..< nleaves:
    var leaf = newSeq[byte](32)
    leaf[^1] = byte(i mod 256)
    leaves.add(leaf)
  leaves

suite "Flat Merkle index helpers":
  test "should reject empty trees and invalid indices":
    check:
      layerWidth(0, 0).isErr
      levels(0).isErr
      levelOffset(0, 0).isErr
      flatIndex(0, 0, 0).isErr
      totalNodes(0).isErr
      layerWidth(1, -1).isErr
      levelOffset(1, -1).isErr
      flatIndex(1, 0, -1).isErr
      flatIndex(1, 0, 1).isErr
      flatIndex(1, 2, 0).isErr

  test "should preserve single leaf tree shape":
    check:
      levels(1).tryGet == 2
      layerWidth(1, 0).tryGet == 1
      layerWidth(1, 1).tryGet == 1
      levelOffset(1, 0).tryGet == 0
      levelOffset(1, 1).tryGet == 1
      flatIndex(1, 0, 0).tryGet == 0
      flatIndex(1, 1, 0).tryGet == 1
      totalNodes(1).tryGet == 2

  test "should compute flat offsets for representative tree sizes":
    for nleaves in [1, 2, 3, 4, 5, 31, 32, 33, 1024, 1025]:
      let widths = expectedWidths(nleaves)
      check:
        levels(nleaves).tryGet == widths.len
        totalNodes(nleaves).tryGet == expectedTotal(widths)

      var offset = 0
      for level, width in widths:
        check:
          layerWidth(nleaves, level).tryGet == width
          levelOffset(nleaves, level).tryGet == offset
          flatIndex(nleaves, level, 0).tryGet == offset
          flatIndex(nleaves, level, width - 1).tryGet == offset + width - 1
          flatIndex(nleaves, level, width).isErr
        offset += width

      check:
        layerWidth(nleaves, widths.len).isErr
        levelOffset(nleaves, widths.len).isErr
        flatIndex(nleaves, widths.len, 0).isErr

  test "should match current ArchivistTree layer shape":
    for nleaves in [1, 2, 3, 4, 5, 9, 10, 31, 32, 33]:
      let tree = ArchivistTree.init(sha256, makeLeaves(nleaves)).tryGet
      check:
        levels(nleaves).tryGet == tree.levels
        totalNodes(nleaves).tryGet == toSeq(tree.nodes).len

      var offset = 0
      for level, layer in tree.layers:
        check:
          layerWidth(nleaves, level).tryGet == layer.len
          levelOffset(nleaves, level).tryGet == offset
        for index in 0 ..< layer.len:
          check flatIndex(nleaves, level, index).tryGet == offset + index
        offset += layer.len

  test "should match current Poseidon2Tree layer shape":
    for nleaves in [1, 2, 3, 4, 5, 9, 10, 31, 32, 33]:
      let tree = Poseidon2Tree.init(newSeq[Poseidon2Hash](nleaves)).tryGet
      check:
        levels(nleaves).tryGet == tree.levels
        totalNodes(nleaves).tryGet == toSeq(tree.nodes).len

      var offset = 0
      for level, layer in tree.layers:
        check:
          layerWidth(nleaves, level).tryGet == layer.len
          levelOffset(nleaves, level).tryGet == offset
        for index in 0 ..< layer.len:
          check flatIndex(nleaves, level, index).tryGet == offset + index
        offset += layer.len
