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

import ../blockstore
import ../../clock
import ../../errors
import ../../merkletree
import ../../systemclock
import ../../units

export kvstore

const
  DefaultDatasetTtl* = 30.days
  DefaultQuotaBytes* = 20.GiBs

type
  QuotaNotEnoughError* = object of ArchivistError

  RepoStore* = ref object of BlockStore
    metaStore*: KVStore ## SQLiteKVStore for metadata (refcounts, quota, proofs)
    blockStore*: KVStore ## FSKVStore for raw block data
    clock*: Clock
    quotaMaxBytes*: NBytes
    quotaUsage*: QuotaUsage ## Cached in-memory, persisted to metaStore
    totalBlocks*: Natural ## Cached in-memory
    started*: bool

  QuotaUsage* {.serialize.} = object
    used*: NBytes
    reserved*: NBytes

  BlockMetadata* {.serialize.} = object
    size*: NBytes
    refCount*: Natural

  LeafMetadata* {.serialize.} = object
    blkCid*: Cid
    proof*: ArchivistProof

  BlockExpiration* {.serialize, deprecated.} = object
    cid*: Cid
    expiry*: SecondsSince1970

  DeleteResultKind* {.serialize.} = enum
    Deleted = 0 # block removed from store
    InUse = 1 # block not removed, refCount > 0 and not expired
    NotFound = 2 # block not found in store

  DeleteResult* {.serialize.} = object
    kind*: DeleteResultKind
    released*: NBytes

  StoreResultKind* {.serialize.} = enum
    Stored = 0 # new block stored
    AlreadyInStore = 1 # block already in store

  StoreResult* {.serialize.} = object
    kind*: StoreResultKind
    used*: NBytes

func quotaUsedBytes*(self: RepoStore): NBytes =
  self.quotaUsage.used

func quotaReservedBytes*(self: RepoStore): NBytes =
  self.quotaUsage.reserved

func totalUsed*(self: RepoStore): NBytes =
  (self.quotaUsedBytes + self.quotaReservedBytes)

func available*(self: RepoStore): NBytes =
  return self.quotaMaxBytes - self.totalUsed

func available*(self: RepoStore, bytes: NBytes): bool =
  return bytes < self.available()

func new*(
    T: type RepoStore,
    metaStore: KVStore,
    blockStore: KVStore,
    clock: Clock = SystemClock.new(),
    quotaMaxBytes = DefaultQuotaBytes,
): RepoStore =
  ## Create new instance of a RepoStore
  ##
  RepoStore(
    metaStore: metaStore,
    blockStore: blockStore,
    clock: clock,
    quotaMaxBytes: quotaMaxBytes,
    onBlockStored: CidCallback.none,
  )
