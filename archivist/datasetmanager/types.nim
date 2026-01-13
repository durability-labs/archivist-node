## Copyright (c) 2025 Archivist Authors
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## Core types for DatasetManager
##
## This module defines the data structures used throughout the dataset
## management system. Types are kept separate to avoid circular dependencies.

{.push raises: [].}

import pkg/chronos
import pkg/libp2p/cid
import pkg/libp2p/multicodec
import pkg/serde

import ../clock

export cid, chronos, multicodec

type
  DatasetStatus* {.serialize.} = enum
    Storing ## Upload in progress (temp overlay protecting blocks)
    Downloading ## Download in progress (includes paused/partial)
    Completed ## All blocks received/stored
    Deleting ## Deletion in progress
    Error ## Unrecoverable error

  CleanupMode* {.serialize.} = enum
    ## Mode for cleaning up after storage request
    SlotsOnly ## Delete slot overlays, keep dataset
    Full ## Delete both slots and dataset
    None ## Keep everything

  OverlayMetadata* {.serialize.} = object
    ## Transient local state for an overlay - manifest is source of truth for dataset metadata.
    ## Overlay type is implicit (determined by loading manifest):
    ##   - protected=false → original dataset
    ##   - protected=true, verifiable=false → protected dataset
    ##   - protected=true, verifiable=true → slot
    status*: DatasetStatus
    manifestCid*: Cid ## For Storing: tempId placeholder; otherwise real manifest CID
    expiry*: SecondsSince1970
    downloadedBlocks*: seq[byte] ## Bitmap (bit N = block N present)

  # Note: presentBlocks is runtime-only, derived on startup from leaf mappings
  # It is NOT stored in OverlayMetadata to avoid serialization
  OverlayState* = object ## Runtime state for an overlay (not persisted)
    metadata*: OverlayMetadata
    presentBlocks*: uint32 ## Derived from leaf mappings on startup
