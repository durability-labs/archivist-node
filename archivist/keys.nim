## Copyright (c) 2025 Archivist Authors
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## Consolidated key builders for all storage namespaces
##
## Key Schema:
##
## | Key Template | Description |
## |--------------|-------------|
## | `/block/{cid}` | Raw block payload (immutable) |
## | `/meta/blocks/{cid}` | Block metadata (refcount, size) |
## | `/meta/datasets/{treeCid}` | Dataset overlay metadata |
## | `/meta/datasets/{treeCid}/leaf/{index}` | Leaf index -> block CID mapping |
## | `/meta/datasets/{treeCid}/slots/{verificationRoot}` | Slot verification root |
## | `/meta/datasets/{treeCid}/slots/{verificationRoot}/{slotRoot}` | Slot overlay metadata |
## | `/meta/datasets/{treeCid}/slots/{verificationRoot}/{slotRoot}/leaf/{index}` | Slot leaf mapping |
## | `/meta/datasets/{treeCid}/slots/{verificationRoot}/tree/{nodeIndex}` | Slot verification tree nodes |
## | `/meta/datasets/{treeCid}/slots/{verificationRoot}/{slotRoot}/tree/{nodeIndex}` | Slot tree nodes |
## | `/meta/tree/{treeCid}/{nodeIndex}` | Merkle tree nodes |
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
  MetaBaseKey* = Key.init(MetaNamespace).tryGet
  BlockBaseKey* = Key.init(BlockNamespace).tryGet
  BlocksMetaBaseKey* = Key.init(BlocksMetaNamespace).tryGet
  TotalBlocksKey* = (BlocksMetaBaseKey / "total").tryGet
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

func datasetOverlayKey*(treeCid: Cid): ?!Key =
  ## Key for dataset overlay metadata: /meta/datasets/{treeCid}
  DatasetsBaseKey / $treeCid

func datasetLeafKey*(treeCid: Cid, index: Natural): ?!Key =
  ## Key for leaf mapping: /meta/datasets/{treeCid}/leaf/{index}
  let base = ?(DatasetsBaseKey / $treeCid)
  let withLeaf = ?(base / LeafSegment)
  withLeaf / $index

func datasetsQueryKey*(): ?!Key =
  ## Query key for iterating all datasets: /meta/datasets/*
  Key.init(DatasetsNamespace & "/*")

# === Slot keys ===

func slotsNamespaceKey*(treeCid: Cid): ?!Key =
  ## Key for slots namespace (for iteration): /meta/datasets/{treeCid}/slots
  let base = ?(DatasetsBaseKey / $treeCid)
  base / SlotsSegment

func slotVerificationRootKey*(treeCid: Cid, verificationRoot: Cid): ?!Key =
  ## Key for slot verification root: /meta/datasets/{treeCid}/slots/{verificationRoot}
  let base = ?slotsNamespaceKey(treeCid)
  base / $verificationRoot

func slotOverlayKey*(treeCid: Cid, verificationRoot: Cid, slotRoot: Cid): ?!Key =
  ## Key for slot overlay metadata: /meta/datasets/{treeCid}/slots/{verificationRoot}/{slotRoot}
  let base = ?slotVerificationRootKey(treeCid, verificationRoot)
  base / $slotRoot

func slotLeafKey*(
    treeCid: Cid, verificationRoot: Cid, slotRoot: Cid, index: Natural
): ?!Key =
  ## Key for slot leaf mapping: /meta/datasets/{treeCid}/slots/{verificationRoot}/{slotRoot}/leaf/{index}
  let base = ?slotOverlayKey(treeCid, verificationRoot, slotRoot)
  let withLeaf = ?(base / LeafSegment)
  withLeaf / $index

func slotVerificationTreeNodeKey*(
    treeCid: Cid, verificationRoot: Cid, nodeIndex: Natural
): ?!Key =
  ## Key for slot verification tree node: /meta/datasets/{treeCid}/slots/{verificationRoot}/tree/{nodeIndex}
  let base = ?slotVerificationRootKey(treeCid, verificationRoot)
  let withTree = ?(base / TreeSegment)
  withTree / $nodeIndex

func slotTreeNodeKey*(
    treeCid: Cid, verificationRoot: Cid, slotRoot: Cid, nodeIndex: Natural
): ?!Key =
  ## Key for slot tree node: /meta/datasets/{treeCid}/slots/{verificationRoot}/{slotRoot}/tree/{nodeIndex}
  let base = ?slotOverlayKey(treeCid, verificationRoot, slotRoot)
  let withTree = ?(base / TreeSegment)
  withTree / $nodeIndex

func slotsQueryKey*(treeCid: Cid): ?!Key =
  ## Query key for iterating all slots of a dataset: /meta/datasets/{treeCid}/slots/*
  let base = ?slotsNamespaceKey(treeCid)
  Key.init($base & "/*")

func slotsForVerificationRootQueryKey*(treeCid: Cid, verificationRoot: Cid): ?!Key =
  ## Query key for iterating slots under a verification root: /meta/datasets/{treeCid}/slots/{verificationRoot}/*
  let base = ?slotVerificationRootKey(treeCid, verificationRoot)
  Key.init($base & "/*")

# === Merkle tree keys ===

func treeNodeKey*(treeCid: Cid, nodeIndex: Natural): ?!Key =
  ## Key for merkle tree node: /meta/tree/{treeCid}/{nodeIndex}
  let base = ?(TreeBaseKey / $treeCid)
  base / $nodeIndex

func treeMetadataKey*(treeCid: Cid): ?!Key =
  ## Key for tree metadata (nleaves, mcodec): /meta/tree/{treeCid}/meta
  let base = ?(TreeBaseKey / $treeCid)
  base / "meta"

func treeQueryKey*(treeCid: Cid): ?!Key =
  ## Query key for iterating all tree nodes: /meta/tree/{treeCid}/*
  let base = ?(TreeBaseKey / $treeCid)
  Key.init($base & "/*")

# === Leaf mapping query keys ===

func datasetLeavesQueryKey*(treeCid: Cid): ?!Key =
  ## Query key for iterating all leaf mappings: /meta/datasets/{treeCid}/leaf/*
  let base = ?(DatasetsBaseKey / $treeCid)
  let withLeaf = ?(base / LeafSegment)
  Key.init($withLeaf & "/*")

func slotLeavesQueryKey*(treeCid: Cid, verificationRoot: Cid, slotRoot: Cid): ?!Key =
  ## Query key for iterating all slot leaf mappings
  let base = ?slotOverlayKey(treeCid, verificationRoot, slotRoot)
  let withLeaf = ?(base / LeafSegment)
  Key.init($withLeaf & "/*")
