## Copyright (c) 2025 Archivist Authors
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/questionable/results
import pkg/libp2p
import pkg/unittest2

import pkg/archivist/keys

# Use hardcoded CID strings to avoid MultiHash.digest compilation issues
const
  Cid1Str = "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi"
  Cid2Str = "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdj"
  Cid3Str = "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdk"

suite "DatasetManager Keys":
  var
    cid1: Cid
    cid2: Cid
    cid3: Cid

  setup:
    cid1 = Cid.init(Cid1Str).tryGet
    cid2 = Cid.init(Cid2Str).tryGet
    cid3 = Cid.init(Cid3Str).tryGet

  # === Block keys ===

  test "blockKey should create /block/{cid}":
    let key = blockKey(cid1).tryGet
    let namespaces = key.namespaces

    check:
      namespaces.len == 2
      namespaces[0].value == "block"
      namespaces[1].value == $cid1

  test "blockMetaKey should create /meta/blocks/{cid}":
    let key = blockMetaKey(cid1).tryGet
    let namespaces = key.namespaces

    check:
      namespaces.len == 3
      namespaces[0].value == "meta"
      namespaces[1].value == "blocks"
      namespaces[2].value == $cid1

  # === Dataset overlay keys ===

  test "datasetOverlayKey should create /meta/datasets/{manifestCid}":
    let key = datasetOverlayKey(cid1).tryGet
    let namespaces = key.namespaces

    check:
      namespaces.len == 3
      namespaces[0].value == "meta"
      namespaces[1].value == "datasets"
      namespaces[2].value == $cid1

  test "datasetLeafKey should create /meta/datasets/{rootCid}/leaf/{index}":
    let key = datasetLeafKey(cid1, 42).tryGet
    let namespaces = key.namespaces

    check:
      namespaces.len == 5
      namespaces[0].value == "meta"
      namespaces[1].value == "datasets"
      namespaces[2].value == $cid1
      namespaces[3].value == "leaf"
      namespaces[4].value == "42"

  test "datasetsQueryKey should create /meta/datasets/*":
    let key = datasetsQueryKey().tryGet
    let namespaces = key.namespaces

    check:
      namespaces.len == 3
      namespaces[0].value == "meta"
      namespaces[1].value == "datasets"
      namespaces[2].value == "*"

  # === Slot keys ===

  test "slotsNamespaceKey should create /meta/datasets/{rootCid}/slots":
    let key = slotsNamespaceKey(cid1).tryGet
    let namespaces = key.namespaces

    check:
      namespaces.len == 4
      namespaces[0].value == "meta"
      namespaces[1].value == "datasets"
      namespaces[2].value == $cid1
      namespaces[3].value == "slots"

  test "slotVerificationRootKey should create /meta/datasets/{rootCid}/slots/{verificationRoot}":
    let key = slotVerificationRootKey(cid1, cid2).tryGet
    let namespaces = key.namespaces

    check:
      namespaces.len == 5
      namespaces[0].value == "meta"
      namespaces[1].value == "datasets"
      namespaces[2].value == $cid1
      namespaces[3].value == "slots"
      namespaces[4].value == $cid2

  test "slotOverlayKey should create /meta/datasets/{rootCid}/slots/{verificationRoot}/{slotRoot}":
    let key = slotOverlayKey(cid1, cid2, cid3).tryGet
    let namespaces = key.namespaces

    check:
      namespaces.len == 6
      namespaces[0].value == "meta"
      namespaces[1].value == "datasets"
      namespaces[2].value == $cid1
      namespaces[3].value == "slots"
      namespaces[4].value == $cid2
      namespaces[5].value == $cid3

  test "slotLeafKey should create correct key":
    let key = slotLeafKey(cid1, cid2, cid3, 99).tryGet
    let namespaces = key.namespaces

    check:
      namespaces.len == 8
      namespaces[0].value == "meta"
      namespaces[1].value == "datasets"
      namespaces[2].value == $cid1
      namespaces[3].value == "slots"
      namespaces[4].value == $cid2
      namespaces[5].value == $cid3
      namespaces[6].value == "leaf"
      namespaces[7].value == "99"

  test "slotVerificationTreeNodeKey should create correct key":
    let key = slotVerificationTreeNodeKey(cid1, cid2, 7).tryGet
    let namespaces = key.namespaces

    check:
      namespaces.len == 7
      namespaces[0].value == "meta"
      namespaces[1].value == "datasets"
      namespaces[2].value == $cid1
      namespaces[3].value == "slots"
      namespaces[4].value == $cid2
      namespaces[5].value == "tree"
      namespaces[6].value == "7"

  test "slotTreeNodeKey should create correct key":
    let key = slotTreeNodeKey(cid1, cid2, cid3, 15).tryGet
    let namespaces = key.namespaces

    check:
      namespaces.len == 8
      namespaces[0].value == "meta"
      namespaces[1].value == "datasets"
      namespaces[2].value == $cid1
      namespaces[3].value == "slots"
      namespaces[4].value == $cid2
      namespaces[5].value == $cid3
      namespaces[6].value == "tree"
      namespaces[7].value == "15"

  test "slotsQueryKey should create /meta/datasets/{rootCid}/slots/*":
    let key = slotsQueryKey(cid1).tryGet
    let namespaces = key.namespaces

    check:
      namespaces.len == 5
      namespaces[0].value == "meta"
      namespaces[1].value == "datasets"
      namespaces[2].value == $cid1
      namespaces[3].value == "slots"
      namespaces[4].value == "*"

  test "slotsForVerificationRootQueryKey should create correct query key":
    let key = slotsForVerificationRootQueryKey(cid1, cid2).tryGet
    let namespaces = key.namespaces

    check:
      namespaces.len == 6
      namespaces[0].value == "meta"
      namespaces[1].value == "datasets"
      namespaces[2].value == $cid1
      namespaces[3].value == "slots"
      namespaces[4].value == $cid2
      namespaces[5].value == "*"

  # === Merkle tree keys ===

  test "treeNodeKey should create /meta/tree/{rootCid}/{nodeIndex}":
    let key = treeNodeKey(cid1, 123).tryGet
    let namespaces = key.namespaces

    check:
      namespaces.len == 4
      namespaces[0].value == "meta"
      namespaces[1].value == "tree"
      namespaces[2].value == $cid1
      namespaces[3].value == "123"

  test "treeQueryKey should create /meta/tree/{rootCid}/*":
    let key = treeQueryKey(cid1).tryGet
    let namespaces = key.namespaces

    check:
      namespaces.len == 4
      namespaces[0].value == "meta"
      namespaces[1].value == "tree"
      namespaces[2].value == $cid1
      namespaces[3].value == "*"

  # === Leaf mapping query keys ===

  test "datasetLeavesQueryKey should create /meta/datasets/{rootCid}/leaf/*":
    let key = datasetLeavesQueryKey(cid1).tryGet
    let namespaces = key.namespaces

    check:
      namespaces.len == 5
      namespaces[0].value == "meta"
      namespaces[1].value == "datasets"
      namespaces[2].value == $cid1
      namespaces[3].value == "leaf"
      namespaces[4].value == "*"

  test "slotLeavesQueryKey should create correct query key":
    let key = slotLeavesQueryKey(cid1, cid2, cid3).tryGet
    let namespaces = key.namespaces

    check:
      namespaces.len == 8
      namespaces[0].value == "meta"
      namespaces[1].value == "datasets"
      namespaces[2].value == $cid1
      namespaces[3].value == "slots"
      namespaces[4].value == $cid2
      namespaces[5].value == $cid3
      namespaces[6].value == "leaf"
      namespaces[7].value == "*"

  # === Quota keys ===

  test "QuotaUsedKey should be /meta/quota/used":
    let namespaces = QuotaUsedKey.namespaces

    check:
      namespaces.len == 3
      namespaces[0].value == "meta"
      namespaces[1].value == "quota"
      namespaces[2].value == "used"

  test "QuotaReservedKey should be /meta/quota/reserved":
    let namespaces = QuotaReservedKey.namespaces

    check:
      namespaces.len == 3
      namespaces[0].value == "meta"
      namespaces[1].value == "quota"
      namespaces[2].value == "reserved"
