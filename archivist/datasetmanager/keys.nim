## Copyright (c) 2025 Archivist Authors
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## Key builders for DatasetManager namespaces
##
## Key Schema (from design doc):
##
## | Key Template | Description |
## |--------------|-------------|
## | `/block/{cid}` | Raw block payload (immutable) |
## | `/meta/blocks/{cid}` | Block metadata (refcount, size) |
## | `/meta/datasets/{manifestCid}` | Dataset overlay metadata |
## | `/meta/datasets/{rootCid}/leaf/{index}` | Leaf index → block CID mapping |
## | `/meta/datasets/{rootCid}/slots/{verificationRoot}` | Slot verification root |
## | `/meta/datasets/{rootCid}/slots/{verificationRoot}/{slotRoot}` | Slot overlay metadata |
## | `/meta/datasets/{rootCid}/slots/{verificationRoot}/{slotRoot}/leaf/{index}` | Slot leaf mapping |
## | `/meta/datasets/{rootCid}/slots/{verificationRoot}/tree/{nodeIndex}` | Slot verification tree nodes |
## | `/meta/datasets/{rootCid}/slots/{verificationRoot}/{slotRoot}/tree/{nodeIndex}` | Slot tree nodes |
## | `/meta/tree/{rootCid}/{nodeIndex}` | Merkle tree nodes |
## | `/meta/quota/used` | Bytes currently stored |
## | `/meta/quota/reserved` | Bytes reserved for pending operations |

{.push raises: [].}

import pkg/kvstore/key
import pkg/libp2p/cid
import pkg/questionable/results

export key

# Namespace constants
const
  BlockNamespace* = "/block"
  MetaNamespace* = "/meta"
  BlocksMetaNamespace* = MetaNamespace & "/blocks"
  DatasetsNamespace* = MetaNamespace & "/datasets"
  TreeNamespace* = MetaNamespace & "/tree"
  QuotaNamespace* = MetaNamespace & "/quota"
  LeafSegment* = "leaf"
  SlotsSegment* = "slots"
  TreeSegment* = "tree"

# Base keys (compile-time constants)
const
  BlockBaseKey* = Key.init(BlockNamespace).tryGet
  BlocksMetaBaseKey* = Key.init(BlocksMetaNamespace).tryGet
  DatasetsBaseKey* = Key.init(DatasetsNamespace).tryGet
  TreeBaseKey* = Key.init(TreeNamespace).tryGet
  QuotaBaseKey* = Key.init(QuotaNamespace).tryGet
  QuotaUsedKey* = (QuotaBaseKey / "used").tryGet
  QuotaReservedKey* = (QuotaBaseKey / "reserved").tryGet

# === Block keys ===

func blockKey*(cid: Cid): ?!Key =
  ## Key for raw block data: /block/{cid}
  BlockBaseKey / $cid

func blockMetaKey*(cid: Cid): ?!Key =
  ## Key for block metadata: /meta/blocks/{cid}
  BlocksMetaBaseKey / $cid

# === Dataset overlay keys ===

func datasetOverlayKey*(manifestCid: Cid): ?!Key =
  ## Key for dataset overlay metadata: /meta/datasets/{manifestCid}
  DatasetsBaseKey / $manifestCid

func datasetLeafKey*(rootCid: Cid, index: Natural): ?!Key =
  ## Key for leaf mapping: /meta/datasets/{rootCid}/leaf/{index}
  let base = ?(DatasetsBaseKey / $rootCid)
  let withLeaf = ?(base / LeafSegment)
  withLeaf / $index

func datasetsQueryKey*(): ?!Key =
  ## Query key for iterating all datasets: /meta/datasets/*
  Key.init(DatasetsNamespace & "/*")

# === Slot keys ===

func slotsNamespaceKey*(rootCid: Cid): ?!Key =
  ## Key for slots namespace (for iteration): /meta/datasets/{rootCid}/slots
  let base = ?(DatasetsBaseKey / $rootCid)
  base / SlotsSegment

func slotVerificationRootKey*(rootCid: Cid, verificationRoot: Cid): ?!Key =
  ## Key for slot verification root: /meta/datasets/{rootCid}/slots/{verificationRoot}
  let base = ?slotsNamespaceKey(rootCid)
  base / $verificationRoot

func slotOverlayKey*(rootCid: Cid, verificationRoot: Cid, slotRoot: Cid): ?!Key =
  ## Key for slot overlay metadata: /meta/datasets/{rootCid}/slots/{verificationRoot}/{slotRoot}
  let base = ?slotVerificationRootKey(rootCid, verificationRoot)
  base / $slotRoot

func slotLeafKey*(
    rootCid: Cid, verificationRoot: Cid, slotRoot: Cid, index: Natural
): ?!Key =
  ## Key for slot leaf mapping: /meta/datasets/{rootCid}/slots/{verificationRoot}/{slotRoot}/leaf/{index}
  let base = ?slotOverlayKey(rootCid, verificationRoot, slotRoot)
  let withLeaf = ?(base / LeafSegment)
  withLeaf / $index

func slotVerificationTreeNodeKey*(
    rootCid: Cid, verificationRoot: Cid, nodeIndex: Natural
): ?!Key =
  ## Key for slot verification tree node: /meta/datasets/{rootCid}/slots/{verificationRoot}/tree/{nodeIndex}
  let base = ?slotVerificationRootKey(rootCid, verificationRoot)
  let withTree = ?(base / TreeSegment)
  withTree / $nodeIndex

func slotTreeNodeKey*(
    rootCid: Cid, verificationRoot: Cid, slotRoot: Cid, nodeIndex: Natural
): ?!Key =
  ## Key for slot tree node: /meta/datasets/{rootCid}/slots/{verificationRoot}/{slotRoot}/tree/{nodeIndex}
  let base = ?slotOverlayKey(rootCid, verificationRoot, slotRoot)
  let withTree = ?(base / TreeSegment)
  withTree / $nodeIndex

func slotsQueryKey*(rootCid: Cid): ?!Key =
  ## Query key for iterating all slots of a dataset: /meta/datasets/{rootCid}/slots/*
  let base = ?slotsNamespaceKey(rootCid)
  Key.init($base & "/*")

func slotsForVerificationRootQueryKey*(rootCid: Cid, verificationRoot: Cid): ?!Key =
  ## Query key for iterating slots under a verification root: /meta/datasets/{rootCid}/slots/{verificationRoot}/*
  let base = ?slotVerificationRootKey(rootCid, verificationRoot)
  Key.init($base & "/*")

# === Merkle tree keys ===

func treeNodeKey*(rootCid: Cid, nodeIndex: Natural): ?!Key =
  ## Key for merkle tree node: /meta/tree/{rootCid}/{nodeIndex}
  let base = ?(TreeBaseKey / $rootCid)
  base / $nodeIndex

func treeQueryKey*(rootCid: Cid): ?!Key =
  ## Query key for iterating all tree nodes: /meta/tree/{rootCid}/*
  let base = ?(TreeBaseKey / $rootCid)
  Key.init($base & "/*")

# === Leaf mapping query keys ===

func datasetLeavesQueryKey*(rootCid: Cid): ?!Key =
  ## Query key for iterating all leaf mappings: /meta/datasets/{rootCid}/leaf/*
  let base = ?(DatasetsBaseKey / $rootCid)
  let withLeaf = ?(base / LeafSegment)
  Key.init($withLeaf & "/*")

func slotLeavesQueryKey*(rootCid: Cid, verificationRoot: Cid, slotRoot: Cid): ?!Key =
  ## Query key for iterating all slot leaf mappings
  let base = ?slotOverlayKey(rootCid, verificationRoot, slotRoot)
  let withLeaf = ?(base / LeafSegment)
  Key.init($withLeaf & "/*")
