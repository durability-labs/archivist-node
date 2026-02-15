## Copyright (c) 2025 Archivist Authors
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## Protobuf serialization for OverlayMetadata
##
## ```protobuf
## message OverlayMetadata {
##   uint32 status = 1;      # OverlayStatus enum
##   uint64 expiry = 2;      # SecondsSince1970
##   bytes  blocks = 3;      # Bitmap (bit N = block N present)
##   bytes  manifestCid = 4; # Cid bytes (optional, for cleanup)
## }
## ```

{.push raises: [].}

import pkg/libp2p/[cid, protobuf/minprotobuf]
import pkg/questionable
import pkg/questionable/results
import pkg/stew/bitseqs

import ../types
import ../../../errors

proc encode*(meta: OverlayMetadata): seq[byte] =
  ## Encode OverlayMetadata to protobuf bytes
  ##

  var pb = initProtoBuffer()

  pb.write(1, meta.status.uint32)
  pb.write(2, meta.expiry.uint64)

  let blocksBytes = seq[byte](meta.blocks)
  if blocksBytes.len > 0:
    pb.write(3, blocksBytes)

  if manifestCid =? meta.manifestCid:
    pb.write(4, manifestCid.data.buffer)

  pb.finish()
  pb.buffer

proc decode*(T: type OverlayMetadata, data: openArray[byte]): ?!T =
  ## Decode OverlayMetadata from protobuf bytes
  ##

  var
    pb = initProtoBuffer(data)
    status: uint32
    expiry: uint64
    blocks: seq[byte]
    manifestCidBytes: seq[byte]

  if pb.getField(1, status).isErr:
    return failure("Unable to decode `status` from OverlayMetadata")

  if pb.getField(2, expiry).isErr:
    return failure("Unable to decode `expiry` from OverlayMetadata")

  discard pb.getField(3, blocks) # Optional field
  discard pb.getField(4, manifestCidBytes) # Optional field

  let manifestCid: ?Cid =
    if manifestCidBytes.len > 0:
      (?Cid.init(manifestCidBytes).mapFailure).some
    else:
      Cid.none

  success OverlayMetadata(
    status: OverlayStatus(status),
    expiry: expiry.int64,
    blocks: BitSeq blocks,
    manifestCid: manifestCid,
  )
