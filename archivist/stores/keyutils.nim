## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/upraises
push:
  {.upraises: [].}

import std/sugar
import pkg/questionable/results
import pkg/datastore
import pkg/libp2p
import ../namespaces
import ../manifest

const
  ArchivistMetaKey* = Key.init(ArchivistMetaNamespace).tryGet
  ArchivistRepoKey* = Key.init(ArchivistRepoNamespace).tryGet
  ArchivistBlocksKey* = Key.init(ArchivistBlocksNamespace).tryGet
  ArchivistTotalBlocksKey* = Key.init(ArchivistBlockTotalNamespace).tryGet
  ArchivistManifestKey* = Key.init(ArchivistManifestNamespace).tryGet
  BlocksTtlKey* = Key.init(ArchivistBlocksTtlNamespace).tryGet
  BlockProofKey* = Key.init(ArchivistBlockProofNamespace).tryGet
  QuotaKey* = Key.init(ArchivistQuotaNamespace).tryGet
  QuotaUsedKey* = (QuotaKey / "used").tryGet
  QuotaReservedKey* = (QuotaKey / "reserved").tryGet

func makePrefixKey*(postFixLen: int, cid: Cid): ?!Key =
  let cidKey = ?Key.init(($cid)[^postFixLen ..^ 1] & "/" & $cid)

  if ?cid.isManifest:
    success ArchivistManifestKey / cidKey
  else:
    success ArchivistBlocksKey / cidKey

proc createBlockExpirationMetadataKey*(cid: Cid): ?!Key =
  BlocksTtlKey / $cid

proc createBlockExpirationMetadataQueryKey*(): ?!Key =
  let queryString = ?(BlocksTtlKey / "*")
  Key.init(queryString)

proc createBlockCidAndProofMetadataKey*(treeCid: Cid, index: Natural): ?!Key =
  (BlockProofKey / $treeCid).flatMap((k: Key) => k / $index)
