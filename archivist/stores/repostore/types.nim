## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2024 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronos
import pkg/kvstore
import pkg/libp2p/cid
import pkg/questionable
import pkg/stew/bitseqs

import ../blockstore
import ../../clock
import ../../errors
import ../../merkletree
import ../../systemclock
import ../../units

const
  DefaultBlockTtl* = 30.days
  DefaultQuotaBytes* = 20.GiBs

type
  QuotaNotEnoughError* = object of ArchivistError

  RepoStore* = ref object of BlockStore
    postFixLen*: int
    repoDs*: KVStore
    metaDs*: KVStore
    clock*: Clock
    quotaMaxBytes*: NBytes
    quotaUsage*: QuotaUsage
    totalBlocks*: Natural
    blockTtl*: Duration
    started*: bool

  QuotaUsage* {.serialize.} = object
    used*: NBytes
    reserved*: NBytes

  BlockMetadata* {.serialize.} = object
    cid*: Cid
    size*: NBytes
    refCount*: Natural

  LeafMetadata* {.serialize.} = object
    deleted*: bool
    blkCid*: Cid
    proof*: ArchivistProof

  OverlayStatus* {.serialize.} = enum
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
    status*: OverlayStatus
    manifestCid*: Cid ## For Storing: tempId placeholder; otherwise real manifest CID
    expiry*: SecondsSince1970
    downloadedBlocks*: BitSeq ## Bitmap (bit N = block N present)

func quotaUsedBytes*(self: RepoStore): NBytes =
  self.quotaUsage.used

func quotaReservedBytes*(self: RepoStore): NBytes =
  self.quotaUsage.reserved

func totalUsed*(self: RepoStore): NBytes =
  (self.quotaUsedBytes + self.quotaReservedBytes)

func available*(self: RepoStore): NBytes =
  return self.quotaMaxBytes - self.totalUsed

func available*(self: RepoStore, bytes: NBytes): bool =
  return bytes <= self.available()

func new*(
    T: type RepoStore,
    repoDs: KVStore,
    metaDs: KVStore,
    clock: Clock = SystemClock.new(),
    postFixLen = 2,
    quotaMaxBytes = DefaultQuotaBytes,
    blockTtl = DefaultBlockTtl,
): RepoStore =
  ## Create new instance of a RepoStore
  ##
  RepoStore(
    repoDs: repoDs,
    metaDs: metaDs,
    clock: clock,
    postFixLen: postFixLen,
    quotaMaxBytes: quotaMaxBytes,
    blockTtl: blockTtl,
    onBlockStored: CidCallback.none,
  )
