import std/random

import pkg/unittest2
import pkg/stew/objects
import pkg/stew/byteutils
import pkg/questionable
import pkg/questionable/results
import pkg/libp2p/protobuf/minprotobuf

import pkg/archivist/clock
import pkg/archivist/merkletree
import pkg/archivist/blocktype as bt
import pkg/archivist/stores/repostore/types
import pkg/archivist/stores/repostore/coders

import ../../helpers
import ../../examples
import ../../merkletree/helpers as mhelpers

suite "Test repostore coders":
  proc rand(T: type NBytes): T =
    rand(Natural).NBytes

  proc rand(E: type[enum]): E =
    let ordinals = enumRangeInt64(E)
    E(ordinals[rand(ordinals.len - 1)])

  proc rand(T: type QuotaUsage): T =
    QuotaUsage(used: rand(NBytes), reserved: rand(NBytes))

  proc rand(T: type Cid): T =
    Cid.example

  proc rand(T: type BlockMetadata): T =
    BlockMetadata(cid: rand(Cid), refCount: rand(Natural))

  test "Natural encode/decode":
    for val in newSeqWith(100, rand(Natural)) & @[Natural.low, Natural.high]:
      check:
        success(val) == Natural.decode(encode(val))

  test "QuotaUsage encode/decode":
    for val in newSeqWith(100, rand(QuotaUsage)):
      check:
        success(val) == QuotaUsage.decode(encode(val))

  test "BlockMetadata encode/decode":
    for val in newSeqWith(100, rand(BlockMetadata)):
      check:
        success(val) == BlockMetadata.decode(encode(val))

  test "LeafMetadata encode/decode":
    let
      nodes = @[newSeqWith(32, rand(byte)), newSeqWith(32, rand(byte))]
      proof = ArchivistProof.init(index = 0, nleaves = 4, nodes = nodes).tryGet()
      val = LeafMetadata(deleted: false, blkCid: Cid.example, proof: proof.some)
      decoded = LeafMetadata.decode(encode(val)).tryGet()

    check:
      decoded.deleted == val.deleted
      decoded.blkCid == val.blkCid
      decoded.proof == val.proof

  test "LeafMetadata encode/decode with nil proof":
    let
      val = LeafMetadata(deleted: true, blkCid: Cid.example, proof: ArchivistProof.none)
      decoded = LeafMetadata.decode(encode(val)).tryGet()

    check:
      decoded.deleted == val.deleted
      decoded.blkCid == val.blkCid
      decoded.proof.isNone

  test "LeafMetadata encode/decode with cell variant":
    # Create two different CIDs using blocks
    let
      blkCid = bt.Block.new("block data".toBytes).tryGet().cid
      cellCid = bt.Block.new("cell data".toBytes).tryGet().cid
      nodes = @[newSeqWith(32, rand(byte)), newSeqWith(32, rand(byte))]
      proof = ArchivistProof.init(index = 1, nleaves = 8, nodes = nodes).tryGet()
      val = LeafMetadata(
        deleted: false,
        blkCid: blkCid,
        proof: proof.some,
        isCell: true,
        cellCid: cellCid,
      )
      decoded = LeafMetadata.decode(encode(val)).tryGet()

    check:
      decoded.deleted == val.deleted
      decoded.blkCid == blkCid
      decoded.proof == val.proof
      decoded.isCell == true
      decoded.cellCid == cellCid

  test "LeafMetadata cell variant backwards compatible (non-cell decodes correctly)":
    let
      val =
        LeafMetadata(deleted: false, blkCid: Cid.example, proof: ArchivistProof.none)
      decoded = LeafMetadata.decode(encode(val)).tryGet()

    check:
      decoded.deleted == val.deleted
      decoded.blkCid == val.blkCid
      decoded.isCell == false

  test "LeafMetadata decode with absent proof field (old records load)":
    # Simulate a pre-conversion record: field 3 never written.
    let pb = block:
      var pb = initProtoBuffer()
      pb.write(1, 0'u32)
      pb.write(2, Cid.example.data.buffer)
      pb.finish()
      pb.buffer
    let decoded = LeafMetadata.decode(pb).tryGet()

    check decoded.proof.isNone

  test "LeafMetadata decode with present-but-empty proof field fails loudly":
    # An encoder that writes an empty proof field is buggy - the decode
    # must fail, not silently treat it as no-proof.
    let pb = block:
      var pb = initProtoBuffer()
      pb.write(1, 0'u32)
      pb.write(2, Cid.example.data.buffer)
      pb.write(3, newSeq[byte]())
      pb.finish()
      pb.buffer

    check LeafMetadata.decode(pb).isErr

  test "Default object proof cannot pass the write side":
    # A default-constructed proof encodes to non-empty bytes with
    # InvalidMultiCodec - it must fail on decode, never silently
    # round-trip as a valid proof.
    let
      defaultProof = ArchivistProof()
      encoded = encode(
        LeafMetadata(deleted: false, blkCid: Cid.example, proof: defaultProof.some)
      )

    check:
      defaultProof.encode().len > 0
      LeafMetadata.decode(encoded).isErr
