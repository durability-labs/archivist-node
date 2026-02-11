import std/random

import pkg/unittest2
import pkg/stew/objects
import pkg/questionable
import pkg/questionable/results

import pkg/archivist/clock
import pkg/archivist/stores/repostore/types
import pkg/archivist/stores/repostore/coders

import ../../helpers
import ../../examples

suite "Test coders":
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
    BlockMetadata(cid: rand(Cid), size: rand(NBytes), refCount: rand(Natural))

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
