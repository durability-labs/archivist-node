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
import std/hashes
import std/sequtils
import std/sets
import std/strformat

import pkg/chronos
import pkg/libp2p
import pkg/questionable
import pkg/metrics

import ../protobuf/blockexc
import ../../blocktype
import ../../logutils
import ../../utils/futures
import ../../utils/trackedfutures

import ./errors

export errors

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
  BlockHandle* = Future[BlockDelivery].Raising([CancelledError, EngineError])
  PendingBlocksAbandonHandler* = proc(address: BlockAddress) {.gcsafe, raises: [].}

  ## With the introduction of batching, the semantics of
  ## the shared block handles changed. If two unrelated
  ## batches endup sharing a subset of tha handles, and one
  ## of them cancels it's subset, then what should happen to
  ## the other handles in the batch? This is a valid condition
  ## because of erasure coding - while blocks are downloaded,
  ## erasure coding might be running trying to recover the
  ## remaining blocks, whichever succeeds first will complete/cancel
  ## outstanding requests. To avoid operations from interferring with
  ## each other, we now addressed with two related mechanisms.
  ##
  ## - A block handle now has "owners", the block is active as
  ## long as owners > 0
  ## - Owners are also `BlockHandle` types. This allows continuing
  ## to rely on the already sound Future semantics, without
  ## introducing a separate type, which will atleast partially
  ## reproduce those semantics.
  ##
  ## Instead, the outer owner fasing `BlockHandle` mirrors the underlying
  ## `BlockHandle`, which stays active for as long as `owners > 0` or the block
  ## isn't resolved or failed.
  ##
  ## When cancelling an owner/public `BlockHandle` proxy, the cancellation
  ## doesn't propagate to the wrapped instance (this is similar to the join
  ## operation in chronos), instead we unregister that handle from the `owners`
  ## hashset. Once `owners.len == 0` the underlying future is "failed", which also
  # propagates to the proxies. This is to prevent using it "after free/dispose".
  ##
  ## The neat thing is that for the caller, the wrappers behave as expected - if
  ## more than one code path endups awaiting the `BlockHandle`, cancelling,
  ## completing or failing the handle will work as expected for the caller, but
  ## won't affect the other handles that are awaited by any other caller.
  ##
  BlockReq = object
    handle: BlockHandle
    owners: HashSet[BlockHandle]
    requested: ?PeerId
    requestId: uint64
    startTime: int64
    blockRetries: int

  PendingBlocksManager* = ref object of RootObj
    blockRetries*: int = DefaultBlockRetries
    retryInterval*: Duration = DefaultRetryInterval
    blocks: Table[BlockAddress, BlockReq] # pending Block requests
    # the map between pending request and owned handles
    handles: Table[BlockHandle, BlockAddress]
    lastInclusion*: Moment
    onAbandon*: PendingBlocksAbandonHandler
    handleMonitors: TrackedFutures

func hash*(handle: BlockHandle): Hash =
  cast[pointer](handle).hash

proc updatePendingBlockGauge(p: PendingBlocksManager) =
  archivist_block_exchange_pending_block_requests.set(p.blocks.len.int64)

proc releaseWantHandle*(
  self: PendingBlocksManager, wrapped: BlockHandle
): ?!void {.gcsafe.}

proc addOwner(
    self: PendingBlocksManager, address: BlockAddress
): BlockHandle {.gcsafe.} =
  self.blocks.withValue(address, pending):
    let
      handle = pending.handle
      wrapped = handle.wrap()

    pending[].owners.incl(wrapped)
    self.handles[wrapped] = address

    proc monitorWrapped(): Future[void] {.gcsafe, async: (raises: []).} =
      try:
        discard await wrapped # discard block delivery
      except CatchableError as exc:
        warn "Exception monitoring wrapper blockhande", address, exc = exc.msg
      except CancelledError:
        trace "Cancelling wrapped blockhandle", address

      if err =? self.releaseWantHandle(wrapped).errorOption:
        warn "Unable to release handle", address

    self.handleMonitors.track(monitorWrapped())

    return wrapped

  raiseAssert "Pending block missing while adding owner"

proc getWantHandle*(
    self: PendingBlocksManager, address: BlockAddress, requested: ?PeerId = PeerId.none
): BlockHandle =
  ## Add an event for a block
  ##

  if address notin self.blocks:
    self.blocks[address] = BlockReq(
      handle: BlockHandle.init("pendingBlocks.sharedHandle"),
      requested: requested,
      blockRetries: self.blockRetries,
      startTime: getMonoTime().ticks,
    )
    self.lastInclusion = Moment.now()
    self.updatePendingBlockGauge()

  return self.addOwner(address)

proc getWantHandle*(
    self: PendingBlocksManager, cid: Cid, requested = PeerId.none
): BlockHandle =
  self.getWantHandle(BlockAddress.init(cid), requested)

proc resolve*(self: PendingBlocksManager, blocksDelivery: seq[BlockDelivery]) =
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

proc resolve*(self: PendingBlocksManager, address: BlockAddress, blk: Block) =
  self.resolve(@[BlockDelivery(blk: blk, address: address)])

proc failOwners(
    self: PendingBlocksManager, address: BlockAddress, err: ref EngineError
) {.gcsafe.} =
  self.blocks.withValue(address, req):
    for wrapped in req[].owners:
      if not wrapped.finished:
        wrapped.fail(err)

proc failWantHandle*(
    self: PendingBlocksManager,
    address: BlockAddress,
    errType: typedesc[EngineError],
    msg: string,
) =
  self.blocks.withValue(address, blockReq):
    if not blockReq[].handle.finished:
      let err = (ref errType)(address: address, msg: msg)
      blockReq[].handle.fail(err)
      self.failOwners(address, err)

proc releaseWantHandle*(
    self: PendingBlocksManager, wrapped: BlockHandle
): ?!void {.gcsafe.} =
  self.handles.withValue(wrapped, address):
    let blockAddress = address[]
    self.handles.del(wrapped)
    self.blocks.withValue(blockAddress, req):
      req[].owners.excl(wrapped)
      if req[].owners.len == 0:
        if not req[].handle.finished:
          warn "Abandoning block", address = blockAddress
          req[].handle.fail(
            newException(
              RequestAbandonedEngineError, fmt"Abandoning block {blockAddress}"
            )
          )
          if not self.onAbandon.isNil:
            self.onAbandon(blockAddress)
        self.blocks.del(blockAddress)
        self.updatePendingBlockGauge()

      return success()

  failure("Unable to find block handle")

proc cancelAll*(self: PendingBlocksManager): Future[void] {.async: (raises: []).} =
  ## Cancel all outstanding block handles and other futures
  ##

  let cancellations = (
    self.blocks.values.toSeq.mapIt(it.handle) &
    self.blocks.values.toSeq.mapIt(it.owners.toSeq).concat
  ).mapIt(it.cancelAndWait())

  self.handles.clear()
  self.blocks.clear()
  self.updatePendingBlockGauge()

  await noCancel allFutures(cancellations & @[self.handleMonitors.cancelTracked])

func owners*(self: PendingBlocksManager, address: BlockAddress): int =
  self.blocks.withValue(address, pending):
    return pending[].owners.len
  0

func owners*(self: PendingBlocksManager, cid: Cid): int =
  self.owners(BlockAddress.init(cid))

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

func getRequestPeer*(self: PendingBlocksManager, handle: BlockHandle): ?PeerId =
  self.handles.withValue(handle, address):
    return self.getRequestPeer(address[])
  PeerId.none

func getHandleAddress*(self: PendingBlocksManager, handle: BlockHandle): ?BlockAddress =
  self.handles.withValue(handle, address):
    return address[].some
  return BlockAddress.none

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

proc wantListLen*(self: PendingBlocksManager): int =
  self.blocks.len

func len*(self: PendingBlocksManager): int =
  self.blocks.len

func new*(
    T: type PendingBlocksManager,
    retries = DefaultBlockRetries,
    interval = DefaultRetryInterval,
): PendingBlocksManager =
  PendingBlocksManager(
    blockRetries: retries, retryInterval: interval, handleMonitors: TrackedFutures.new()
  )
