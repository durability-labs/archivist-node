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
  ArchivistOverlaysKey* = Key.init(ArchivistOverlayNamespace).tryGet
  BlocksMetaKey* = Key.init(ArchivistBlocksMetaNamespace).tryGet
  BlockLeafKey* = Key.init(ArchivistBlockLeafNamespace).tryGet
  QuotaKey* = Key.init(ArchivistQuotaNamespace).tryGet
  QuotaUsedKey* = (QuotaKey / "used").tryGet
  QuotaReservedKey* = (QuotaKey / "reserved").tryGet

func makePrefixKey*(postFixLen: int, cid: Cid): ?!Key =
  let cidKey = ?Key.init(($cid)[^postFixLen ..^ 1] & "/" & $cid)

  if ?cid.isManifest:
    success ArchivistManifestKey / cidKey
  else:
    success ArchivistBlocksKey / cidKey

func overlayKey*(treeCid: Cid): ?!Key =
  ## Key for dataset overlay metadata: /meta/datasets/{treeCid}
  ArchivistOverlaysKey / $treeCid

func overlayQueryKey*(): ?!Key =
  ## Query key for iterating all datasets: /meta/datasets/*
  Key.init(?(ArchivistOverlaysKey / "*"))

proc blockMetaKey*(cid: Cid): ?!Key =
  BlocksMetaKey / $cid

proc blockMetaKeyQuery*(): ?!Key =
  Key.init(?(BlocksMetaKey / "*"))

proc blockLeafKey*(treeCid: Cid, index: Natural): ?!Key =
  (BlockLeafKey / $treeCid).flatMap((k: Key) => k / $index)

proc blockLeafQueryKey*(treeCid: Cid): ?!Key =
  ## Query key for iterating all leafs under a tree: /meta/leafs/{treeCid}/*
  Key.init(?(BlockLeafKey / $treeCid / "*"))
