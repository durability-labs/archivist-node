## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2024 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## Protobuf serialization for RepoStore metadata types
##
## ```protobuf
## message QuotaUsage {
##   uint64 used = 1;       # NBytes
##   uint64 reserved = 2;   # NBytes
## }
##
## message BlockMetadata {
##   bytes  cid = 1;        # Cid bytes
##   uint64 refCount = 2;   # Natural
## }
##
## message LeafMetadata {
##   uint32 deleted = 1;    # bool as uint
##   bytes  blkCid = 2;     # Cid bytes
##   bytes  proof = 3;      # ArchivistProof bytes (optional)
##   bytes  cellCid = 4;    # the cid of the cell if isCell == true
## }
##
## message TreeNodeMetadata {
##   bytes cid = 1;         # Merkle node CID bytes
## }
## ```

{.push raises: [].}

import pkg/libp2p/[cid, protobuf/minprotobuf]
import pkg/questionable
import pkg/questionable/results
import pkg/stew/endians2

import ./types
import ../../errors
import ../../merkletree

proc encode*(t: QuotaUsage): seq[byte] =
  var pb = initProtoBuffer()
  pb.write(1, t.used.uint64)
  pb.write(2, t.reserved.uint64)
  pb.finish()
  pb.buffer

proc decode*(T: type QuotaUsage, bytes: openArray[byte]): ?!T =
  var
    pb = initProtoBuffer(bytes)
    used: uint64
    reserved: uint64

  if pb.getField(1, used).isErr:
    return failure("Unable to decode `used` from QuotaUsage")

  if pb.getField(2, reserved).isErr:
    return failure("Unable to decode `reserved` from QuotaUsage")

  success QuotaUsage(used: used.NBytes, reserved: reserved.NBytes)

proc encode*(t: BlockMetadata): seq[byte] =
  var pb = initProtoBuffer()
  pb.write(1, t.cid.data.buffer)
  pb.write(2, t.refCount.uint64)
  pb.finish()
  pb.buffer

proc decode*(T: type BlockMetadata, bytes: openArray[byte]): ?!T =
  var
    pb = initProtoBuffer(bytes)
    cidBytes: seq[byte]
    refCount: uint64

  if pb.getField(1, cidBytes).isErr:
    return failure("Unable to decode `cid` from BlockMetadata")

  if pb.getField(2, refCount).isErr:
    return failure("Unable to decode `refCount` from BlockMetadata")

  let blkCid = ?Cid.init(cidBytes).mapFailure

  success BlockMetadata(cid: blkCid, refCount: refCount.Natural)

proc encode*(t: LeafMetadata): seq[byte] =
  var pb = initProtoBuffer()
  pb.write(1, t.deleted.uint32)
  pb.write(2, t.blkCid.data.buffer)

  if proof =? t.proof:
    pb.write(3, proof.encode())

  if t.isCell:
    pb.write(4, t.cellCid.data.buffer)

  pb.finish()
  pb.buffer

proc decode*(T: type LeafMetadata, bytes: openArray[byte]): ?!T =
  var
    pb = initProtoBuffer(bytes)
    deleted: uint32
    blkCidBytes: seq[byte]
    proofBytes: seq[byte]
    cellCidBytes: seq[byte]

  if pb.getField(1, deleted).isErr:
    return failure("Unable to decode `deleted` from LeafMetadata")

  if pb.getField(2, blkCidBytes).isErr:
    return failure("Unable to decode `blkCid` from LeafMetadata")

  discard pb.getField(4, cellCidBytes) # Optional field (cell leaves only)

  let blkCid = ?Cid.init(blkCidBytes).mapFailure

  var proof: ?ArchivistProof
  if ?pb.getField(3, proofBytes).mapFailure:
    without decodedProof =? ArchivistProof.decode(proofBytes), err:
      return failure(err)
    proof = decodedProof.some

  if cellCidBytes.len > 0:
    let cellCid = ?Cid.init(cellCidBytes).mapFailure
    success LeafMetadata(
      deleted: deleted.bool,
      blkCid: blkCid,
      proof: proof,
      isCell: true,
      cellCid: cellCid,
    )
  else:
    success LeafMetadata(deleted: deleted.bool, blkCid: blkCid, proof: proof)

proc encode*(t: TreeNodeMetadata): seq[byte] =
  var pb = initProtoBuffer()
  pb.write(1, t.cid.data.buffer)
  pb.finish()
  pb.buffer

proc decode*(T: type TreeNodeMetadata, bytes: openArray[byte]): ?!T =
  var
    pb = initProtoBuffer(bytes)
    cidBytes: seq[byte]

  if pb.getField(1, cidBytes).isErr:
    return
      failure(newException(TreeNodeValidationError, "Unable to decode tree node CID"))

  success TreeNodeMetadata(cid: ?Cid.init(cidBytes).mapFailure)

proc encode*(i: uint64): seq[byte] =
  @(i.toBytesBE)

proc decode*(T: type uint64, bytes: openArray[byte]): ?!T =
  if bytes.len >= sizeof(uint64):
    success(uint64.fromBytesBE(bytes))
  else:
    failure("Not enough bytes to decode `uint64`")

proc encode*(i: Natural | enum): seq[byte] =
  cast[uint64](i).encode

proc decode*(T: typedesc[Natural | enum], bytes: openArray[byte]): ?!T =
  let ui = ?uint64.decode(bytes)
  when T is enum:
    if ui > T.high.uint64:
      return failure("Invalid enum value " & $ui & " for " & $T)
  success cast[T](ui)
