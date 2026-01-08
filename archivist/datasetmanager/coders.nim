## Copyright (c) 2025 Archivist Authors
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## Protobuf serialization for DatasetManager types
##
## ```protobuf
## message OverlayMetadata {
##   uint32 status = 1;        # DatasetStatus enum
##   bytes manifestCid = 2;    # Cid bytes
##   uint32 totalBlocks = 3;
##   uint64 totalSize = 4;
##   int64 expiry = 5;         # SecondsSince1970
##   uint32 kind = 6;          # OverlayKind enum
##   optional bytes parentTreeCid = 7;  # For SlotOverlay
## }
## ```

{.push raises: [].}

import pkg/libp2p/[cid, protobuf/minprotobuf]
import pkg/questionable
import pkg/questionable/results

import ./types
import ../errors

proc encode*(meta: OverlayMetadata): seq[byte] =
  ## Encode OverlayMetadata to protobuf bytes
  var pb = initProtoBuffer()

  pb.write(1, meta.status.uint32)
  pb.write(2, meta.manifestCid.data.buffer)
  pb.write(3, meta.totalBlocks)
  pb.write(4, meta.totalSize)
  pb.write(5, meta.expiry.uint64)
  pb.write(6, meta.kind.uint32)

  if parentCid =? meta.parentTreeCid:
    pb.write(7, parentCid.data.buffer)

  pb.finish()
  pb.buffer

proc decode*(T: type OverlayMetadata, data: openArray[byte]): ?!T =
  ## Decode OverlayMetadata from protobuf bytes
  var
    pb = initProtoBuffer(data)
    status: uint32
    manifestCidBuf: seq[byte]
    totalBlocks: uint32
    totalSize: uint64
    expiry: uint64
    kind: uint32
    parentTreeCidBuf: seq[byte]

  if pb.getField(1, status).isErr:
    return failure("Unable to decode `status` from OverlayMetadata")

  if pb.getField(2, manifestCidBuf).isErr:
    return failure("Unable to decode `manifestCid` from OverlayMetadata")

  if pb.getField(3, totalBlocks).isErr:
    return failure("Unable to decode `totalBlocks` from OverlayMetadata")

  if pb.getField(4, totalSize).isErr:
    return failure("Unable to decode `totalSize` from OverlayMetadata")

  if pb.getField(5, expiry).isErr:
    return failure("Unable to decode `expiry` from OverlayMetadata")

  if pb.getField(6, kind).isErr:
    return failure("Unable to decode `kind` from OverlayMetadata")

  discard pb.getField(7, parentTreeCidBuf) # Optional field

  let manifestCid = ?Cid.init(manifestCidBuf).mapFailure
  let parentTreeCid =
    if parentTreeCidBuf.len > 0:
      Cid.init(parentTreeCidBuf).mapFailure.option
    else:
      Cid.none

  success(
    OverlayMetadata(
      status: DatasetStatus(status),
      manifestCid: manifestCid,
      totalBlocks: totalBlocks,
      totalSize: totalSize,
      expiry: expiry.int64,
      kind: OverlayKind(kind),
      parentTreeCid: parentTreeCid,
    )
  )
