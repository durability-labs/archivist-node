## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## Utility functions for manifest storage operations

{.push raises: [].}

import pkg/chronos
import pkg/libp2p/cid
import pkg/questionable/results

import ../manifest
import ../blocktype as bt
import ../stores/blockstore
import ../logutils

export blockstore, cid

logScope:
  topics = "archivist manifestutils"

proc fetchManifest*(
    store: BlockStore, cid: Cid
): Future[?!Manifest] {.async: (raises: [CancelledError]).} =
  ## Fetch and decode a manifest from the blockstore
  ##

  if err =? cid.isManifest.errorOption:
    return failure("CID has invalid content type for manifest")

  trace "Retrieving manifest for cid", cid
  let blk = ?await store.getBlock(BlockAddress.init(cid))

  trace "Decoding manifest for cid", cid
  let manifest = ?Manifest.decode(blk)

  trace "Decoded manifest", cid
  success(manifest)

proc storeManifest*(
    store: BlockStore, manifest: Manifest
): Future[?!bt.Block] {.async: (raises: [CancelledError]).} =
  ## Encode and store a manifest to the blockstore
  ##

  let encoded = ?manifest.encode()
  let blk = ?bt.Block.new(data = encoded, codec = ManifestCodec)

  ?await store.putBlock(blk)

  success(blk)
