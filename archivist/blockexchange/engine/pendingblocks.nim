## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license, ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/tables
import std/monotimes

import pkg/chronos
import pkg/libp2p
import pkg/metrics
import pkg/results

import ../protobuf/blockexc
import ../../blocktype
import ../../logutils

logScope:
  topics = "archivist pendingblocks"

declareGauge(
  archivist_block_exchange_pending_block_requests,
  "archivist blockexchange pending block requests",
)
declareGauge(
  archivist_block_exchange_retrieval_time_us,
  "archivist blockexchange block retrieval time us",
)

const
  DefaultBlockRetries* = 3000
  DefaultRetryInterval* = 500.millis

type
  BDError* = object of CatchableError
    address*: BlockAddress

  BDRetriesExhaustedError* = object of BDError
  BDValidationRejectedError* = object of BDError
  BDStorageFailedError* = object of BDError
  BDEngineStoppedError* = object of BDError
  BDQueueFailedError* = object of BDError

  BlockHandle* = Future[BlockDelivery].Raising([CancelledError, BDError])
  PendingBlocksCancelHandler* = proc(address: BlockAddress) {.gcsafe, raises: [].}

  BlockReq* = object
    handle*: BlockHandle
    requested*: ?PeerId
    requestId*: uint64
    blockRetries*: int
    startTime*: int64

  PendingBlocksManager* = ref object of RootObj
    blockRetries*: int = DefaultBlockRetries
    retryInterval*: Duration = DefaultRetryInterval
    blocks*: Table[BlockAddress, BlockReq] # pending Block requests
    lastInclusion*: Moment
    onCancel*: PendingBlocksCancelHandler

proc updatePendingBlockGauge(p: PendingBlocksManager) =
  archivist_block_exchange_pending_block_requests.set(p.blocks.len.int64)

proc getWantHandle*(
    self: PendingBlocksManager, address: BlockAddress, requested: ?PeerId = PeerId.none
): BlockHandle =
  ## Add an event for a block
  ##

  self.blocks.withValue(address, blk):
    return blk[].handle
  do:
    let
      blk = BlockReq(
        handle: BlockHandle.init("pendingBlocks.getWantHandle"),
        requested: requested,
        blockRetries: self.blockRetries,
        startTime: getMonoTime().ticks,
      )

      handle = blk.handle

    self.blocks[address] = blk
    self.lastInclusion = Moment.now()

    proc cleanUpBlock(data: pointer) {.raises: [].} =
      self.blocks.del(address)
      self.updatePendingBlockGauge()

    handle.addCallback(cleanUpBlock)
    handle.cancelCallback = proc(data: pointer) {.raises: [].} =
      if not handle.finished:
        handle.removeCallback(cleanUpBlock)

      if not self.onCancel.isNil:
        self.onCancel(address)
      cleanUpBlock(nil)

    self.updatePendingBlockGauge()

    return handle

proc getWantHandle*(
    self: PendingBlocksManager, cid: Cid, requested = PeerId.none
): BlockHandle =
  self.getWantHandle(BlockAddress.init(cid), requested)

proc completeWantHandle*(
    self: PendingBlocksManager, address: BlockAddress, blk: Block
) =
  ## Complete a pending want handle
  self.blocks.withValue(address, blockReq):
    if not blockReq[].handle.finished:
      trace "Completing want handle from provided block", address
      blockReq[].handle.complete(BlockDelivery(blk: blk, address: address))
    else:
      trace "Want handle already completed", address
  do:
    trace "No pending want handle found for address", address

proc resolve*(
    self: PendingBlocksManager, blocksDelivery: seq[BlockDelivery]
) {.gcsafe.} =
  ## Resolve pending blocks
  ##

  for bd in blocksDelivery:
    self.blocks.withValue(bd.address, blockReq):
      if not blockReq[].handle.finished:
        trace "Resolving pending block", address = bd.address
        let
          startTime = blockReq[].startTime
          stopTime = getMonoTime().ticks
          retrievalDurationUs = (stopTime - startTime) div 1000

        blockReq.handle.complete(bd)

        archivist_block_exchange_retrieval_time_us.set(retrievalDurationUs)

        if retrievalDurationUs > 500000:
          warn "High block retrieval time", retrievalDurationUs, address = bd.address
      else:
        trace "Block handle already finished", address = bd.address

proc failWantHandle*(
    self: PendingBlocksManager, address: BlockAddress, errType: typedesc, msg: string
) =
  self.blocks.withValue(address, blockReq):
    if not blockReq[].handle.finished:
      # trace "Failing want handle", address, kind, msg
      blockReq[].handle.fail(((ref errType)(address: address, msg: msg)))

proc cancelAll*(self: PendingBlocksManager): Future[void] {.async: (raises: []).} =
  var handles: seq[BlockHandle]
  for blockReq in self.blocks.values:
    handles.add(blockReq.handle)

  var cancellations: seq[Future[void]]
  for handle in handles:
    if not handle.finished:
      cancellations.add(handle.cancelAndWait())

  await noCancel allFutures(cancellations)

func retries*(self: PendingBlocksManager, address: BlockAddress): int =
  self.blocks.withValue(address, pending):
    return pending[].blockRetries
  do:
    return 0

func decRetries*(self: PendingBlocksManager, address: BlockAddress) =
  self.blocks.withValue(address, pending):
    pending[].blockRetries -= 1

func retriesExhausted*(self: PendingBlocksManager, address: BlockAddress): bool =
  self.blocks.withValue(address, pending):
    return pending[].blockRetries <= 0
  false

func isRequested*(self: PendingBlocksManager, address: BlockAddress): bool =
  self.blocks.withValue(address, pending):
    return pending[].requested.isSome
  false

func getRequestPeer*(self: PendingBlocksManager, address: BlockAddress): ?PeerId =
  self.blocks.withValue(address, pending):
    return pending[].requested
  PeerId.none

proc markRequested*(
    self: PendingBlocksManager, address: BlockAddress, peer: PeerId
): ?uint64 =
  self.blocks.withValue(address, pending):
    if pending[].requested.isSome:
      return uint64.none

    pending[].requested = peer.some
    pending[].requestId.inc
    return pending[].requestId.some

  uint64.none

func requestId*(self: PendingBlocksManager, address: BlockAddress): ?uint64 =
  self.blocks.withValue(address, pending):
    return pending[].requestId.some
  uint64.none

proc clearRequest*(
    self: PendingBlocksManager, address: BlockAddress, peer: ?PeerId = PeerId.none
) =
  self.blocks.withValue(address, pending):
    if peer.isNone or peer == pending[].requested:
      pending[].requested = PeerId.none

func contains*(self: PendingBlocksManager, cid: Cid): bool =
  BlockAddress.init(cid) in self.blocks

func contains*(self: PendingBlocksManager, address: BlockAddress): bool =
  address in self.blocks

iterator wantList*(self: PendingBlocksManager): BlockAddress =
  for a in self.blocks.keys:
    yield a

iterator wantListBlockCids*(self: PendingBlocksManager): Cid =
  for a in self.blocks.keys:
    if not a.leaf:
      yield a.cid

iterator wantListCids*(self: PendingBlocksManager): Cid =
  var yieldedCids = initHashSet[Cid]()
  for a in self.blocks.keys:
    let cid = a.cidOrTreeCid
    if cid notin yieldedCids:
      yieldedCids.incl(cid)
      yield cid

iterator wantHandles*(self: PendingBlocksManager): BlockHandle =
  for v in self.blocks.values:
    yield v.handle

proc wantListLen*(self: PendingBlocksManager): int =
  self.blocks.len

func len*(self: PendingBlocksManager): int =
  self.blocks.len

func new*(
    T: type PendingBlocksManager,
    retries = DefaultBlockRetries,
    interval = DefaultRetryInterval,
): PendingBlocksManager =
  PendingBlocksManager(blockRetries: retries, retryInterval: interval)
