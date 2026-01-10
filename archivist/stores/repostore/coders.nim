## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2024 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.
##
## Protobuf encoding/decoding for RepoStore metadata types.
## Per AGENTS.md: Use protobuf for persistence, JSON only for REST API.

{.push raises: [].}

import pkg/libp2p/multicodec
import pkg/libp2p/protobuf/minprotobuf
import pkg/questionable/results
import pkg/stew/endians2

import ./types

type TreeMetadata* = object
  nleaves*: Natural
  mcodec*: MultiCodec

## QuotaUsage protobuf encoding
## Field 1: used (uint64)
## Field 2: reserved (uint64)

proc encode*(t: QuotaUsage): seq[byte] =
  var pb = initProtoBuffer()
  pb.write(1, t.used.uint64)
  pb.write(2, t.reserved.uint64)
  pb.finish()
  pb.buffer

proc decode*(T: type QuotaUsage, bytes: openArray[byte]): ?!T =
  var
    pb = initProtoBuffer(bytes)
    used, reserved: uint64

  if pb.getField(1, used).isErr:
    return failure("Unable to decode QuotaUsage.used")
  if pb.getField(2, reserved).isErr:
    return failure("Unable to decode QuotaUsage.reserved")

  success QuotaUsage(used: used.NBytes, reserved: reserved.NBytes)

## BlockMetadata protobuf encoding
## Field 1: size (uint64)
## Field 2: refCount (uint64)

proc encode*(t: BlockMetadata): seq[byte] =
  var pb = initProtoBuffer()
  pb.write(1, t.size.uint64)
  pb.write(2, t.refCount.uint64)
  pb.finish()
  pb.buffer

proc decode*(T: type BlockMetadata, bytes: openArray[byte]): ?!T =
  var
    pb = initProtoBuffer(bytes)
    size, refCount: uint64

  if pb.getField(1, size).isErr:
    return failure("Unable to decode BlockMetadata.size")
  if pb.getField(2, refCount).isErr:
    return failure("Unable to decode BlockMetadata.refCount")

  success BlockMetadata(size: size.NBytes, refCount: refCount.Natural)

## TreeMetadata protobuf encoding
## Field 1: nleaves (uint64)
## Field 2: mcodec (uint64)

proc encode*(t: TreeMetadata): seq[byte] =
  var pb = initProtoBuffer()
  pb.write(1, t.nleaves.uint64)
  pb.write(2, t.mcodec.uint64)
  pb.finish()
  pb.buffer

proc decode*(T: type TreeMetadata, bytes: openArray[byte]): ?!T =
  var
    pb = initProtoBuffer(bytes)
    nleaves, mcodec: uint64

  if pb.getField(1, nleaves).isErr:
    return failure("Unable to decode TreeMetadata.nleaves")
  if pb.getField(2, mcodec).isErr:
    return failure("Unable to decode TreeMetadata.mcodec")

  success TreeMetadata(nleaves: nleaves.Natural, mcodec: mcodec.MultiCodec)

## Simple type encoders for kvstore typed API

proc encode*(i: uint64): seq[byte] =
  @(i.toBytesBE)

proc decode*(T: type uint64, bytes: openArray[byte]): ?!T =
  if bytes.len >= sizeof(uint64):
    success(uint64.fromBytesBE(bytes))
  else:
    failure("Not enough bytes to decode uint64")

proc encode*(i: Natural): seq[byte] =
  i.uint64.encode

proc decode*(T: type Natural, bytes: openArray[byte]): ?!T =
  without val =? uint64.decode(bytes):
    return failure("Unable to decode Natural")
  success val.Natural
