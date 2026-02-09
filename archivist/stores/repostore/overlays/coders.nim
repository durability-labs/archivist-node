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
##   uint32 status = 1;           # OverlayStatus enum
##   bytes manifestCid = 2;       # Cid bytes
##   int64 expiry = 3;            # SecondsSince1970
##   bytes downloadedBlocks = 4;  # Bitmap (bit N = block N present)
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
  if manifest =? meta.manifest:
    pb.write(2, manifest.data.buffer)
  pb.write(3, meta.expiry.uint64)

  if meta.blocks.len > 0:
    pb.write(4, seq[byte] meta.blocks)

  pb.finish()
  pb.buffer

proc decode*(T: type OverlayMetadata, data: openArray[byte]): ?!T =
  ## Decode OverlayMetadata from protobuf bytes
  ##

  var
    pb = initProtoBuffer(data)
    status: uint32
    manifest: seq[byte]
    expiry: uint64
    blocks: seq[byte]

  if pb.getField(1, status).isErr:
    return failure("Unable to decode `status` from OverlayMetadata")

  if pb.getField(2, manifest).isErr:
    return failure("Unable to decode `manifestCid` from OverlayMetadata")

  if pb.getField(3, expiry).isErr:
    return failure("Unable to decode `expiry` from OverlayMetadata")

  discard pb.getField(4, blocks) # Optional field

  let
    cid = ?Cid.init(manifest).mapFailure
    meta = OverlayMetadata(
      status: OverlayStatus(status),
      manifest: some(cid),
      expiry: expiry.int64,
      blocks: BitSeq blocks,
    )

  success meta
