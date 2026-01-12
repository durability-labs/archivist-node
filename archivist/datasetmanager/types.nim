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
import pkg/questionable
import pkg/serde

import ../clock

export cid, chronos, multicodec

type
  DatasetStatus* {.serialize.} = enum
    Downloading ## Download in progress (includes paused/partial)
    Completed ## All blocks received/stored
    Deleting ## Deletion in progress
    Error ## Unrecoverable error

  CleanupMode* {.serialize.} = enum
    ## Mode for cleaning up after storage request
    SlotsOnly ## Delete slot overlays, keep dataset
    Full ## Delete both slots and dataset
    None ## Keep everything

  OverlayKind* {.serialize.} = enum
    ## Type of overlay - 1:1 correspondence with manifest type
    DatasetOverlay ## Original or protected dataset (distinguished by manifest.protected)
    SlotOverlay ## Slot within a protected dataset

  OverlayMetadata* {.serialize.} = object
    ## Metadata for an overlay - 1:1 correspondence with a manifest
    ## Every manifest (original, protected, slot) has exactly one overlay
    status*: DatasetStatus
    manifestCid*: Cid
    merkleCodec*: MultiCodec
    totalBlocks*: uint32
    totalSize*: uint64
    expiry*: SecondsSince1970
    kind*: OverlayKind
    parentTreeCid*: ?Cid ## For SlotOverlay: parent protected dataset tree root

  # Note: presentBlocks is runtime-only, derived on startup from leaf mappings
  # It is NOT stored in OverlayMetadata to avoid serialization
  OverlayState* = object ## Runtime state for an overlay (not persisted)
    metadata*: OverlayMetadata
    presentBlocks*: uint32 ## Derived from leaf mappings on startup
