## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sugar
import pkg/questionable/results
import pkg/kvstore
import pkg/libp2p
import ../namespaces
import ../manifest

{.push raises: [].}

const
  ArchivistMetaKey* = Key.init(ArchivistMetaNamespace).tryGet
  ArchivistRepoKey* = Key.init(ArchivistRepoNamespace).tryGet
  ArchivistBlocksKey* = Key.init(ArchivistBlocksNamespace).tryGet
  ArchivistTotalBlocksKey* = Key.init(ArchivistBlockTotalNamespace).tryGet
  ArchivistManifestKey* = Key.init(ArchivistManifestNamespace).tryGet
  BlocksMetaKey* = Key.init(ArchivistBlocksTtlNamespace).tryGet
    ## Block metadata key (refcount, size). Namespace uses "ttl" for backward compat.
  BlockProofKey* = Key.init(ArchivistBlockProofNamespace).tryGet
  QuotaKey* = Key.init(ArchivistQuotaNamespace).tryGet
  QuotaUsedKey* = (QuotaKey / "used").tryGet

func makeBlockDataKey*(cid: Cid): ?!Key =
  ## Create key for block data in blockStore
  ## FSKVStore handles sharding internally
  if ?cid.isManifest:
    ArchivistManifestKey / $cid
  else:
    ArchivistBlocksKey / $cid

func makeBlockMetadataKey*(cid: Cid): ?!Key =
  ## Create key for block metadata (refcount, size) in metaStore
  BlocksMetaKey / $cid

proc createBlockCidAndProofMetadataKey*(treeCid: Cid, index: Natural): ?!Key =
  ## Create key for leaf metadata (cid + proof) in metaStore
  (BlockProofKey / $treeCid).flatMap((k: Key) => k / $index)
