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
  PendingBlocksTimeoutHandler* =
    proc(address: BlockAddress, peer: PeerId) {.gcsafe, raises: [].}

  ## With the introduction of batching, the semantics of shared block handles
  ## changed. If two unrelated batches share a subset of handles, and one batch
  ## cancels its subset, what should happen to the other handles in the batch?
  ##
  ## This is a valid condition because of erasure coding: while blocks are being
  ## downloaded, erasure recovery might also be running and trying to recover the
  ## remaining blocks. Whichever succeeds first will complete or cancel outstanding
  ## requests. To prevent these operations from interfering with each other, we use
  ## two related mechanisms:
  ##
  ## - A block handle now has "owners"; the block remains active while
  ##   `owners.len > 0`.
  ## - Owners are also `BlockHandle` values. This lets callers keep relying on
  ##   Future semantics without introducing a separate type that would partially
  ##   duplicate those semantics.
  ##
  ## The outer, owner-facing `BlockHandle` mirrors the underlying `BlockHandle`,
  ## which stays active as long as `owners.len > 0` and the block has not been
  ## resolved or failed.
  ##
  ## When an owner/public `BlockHandle` proxy is cancelled, the cancellation does
  ## not propagate to the wrapped instance (similar to Chronos' `join` operation).
  ## Instead, we unregister that handle from the `owners` set. Once
  ## `owners.len == 0`, the underlying future is failed, which also propagates to
  ## the proxies. This prevents using it after it has been released or disposed.
  ##
  ## For callers, the wrappers behave as expected: if more than one code path
  ## awaits the `BlockHandle`, cancelling, completing, or failing one wrapper works
  ## as expected for that caller, but does not affect handles awaited by other
  ## callers.
  ##
  BlockReq = object
    handle: BlockHandle
    owners: HashSet[BlockHandle]
    requested: ?PeerId
    requestTimeout: Future[void]
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
    onTimeout*: PendingBlocksTimeoutHandler
    handleMonitors: TrackedFutures

func hash*(handle: BlockHandle): Hash =
  cast[pointer](handle).hash

proc updatePendingBlockGauge(p: PendingBlocksManager) =
  archivist_block_exchange_pending_block_requests.set(p.blocks.len.int64)

proc clearRequestTimeout(req: var BlockReq) =
  if not req.requestTimeout.isNil and not req.requestTimeout.finished:
    req.requestTimeout.cancelSoon()
  req.requestTimeout = nil

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

        blockReq[].clearRequestTimeout()
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
    blockReq[].clearRequestTimeout()
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
        req[].clearRequestTimeout()
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

  var handles: seq[BlockHandle]
  for req in self.blocks.mvalues:
    req.clearRequestTimeout()
    handles.add(req.handle)
    for owner in req.owners:
      handles.add(owner)

  let cancellations = handles.mapIt(it.cancelAndWait())

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
    self: PendingBlocksManager,
    address: BlockAddress,
    peer: PeerId,
    timeout: Duration = DefaultRetryInterval,
): ?PeerId =
  let requestedPeer = self.getRequestPeer(address)
  if requestedPeer.isSome:
    trace "Block already requested", address, requestedPeer
    return requestedPeer

  self.blocks.withValue(address, pending):
    pending[].requested = peer.some
    proc monitorReqTimeout() {.async: (raising: []).} =
      var timedout = false
      defer:
        if pending.isNil:
          trace "Pending request doesn't exist anymore, it might have completed already",
            address, peer
          return

        let requestedPeer = self.getRequestPeer(address)
        if requestedPeer.isSome and requestedPeer != peer.some:
          warn "Requested and timed out peers don't match, this shouldn't happen!",
            oldPeer = peer, newPeer = requestedPeer, address
          return

        if timedout and not self.onTimeout.isNil:
          pending[].requested = PeerId.none
          self.onTimeout(address, peer)

      try:
        await sleepAsync(timeout)
        timedout = true
      except CatchableError as exc:
        trace "Exception in request timeout monitor", exc = exc.msg

    pending[].requestTimeout = monitorReqTimeout()
    return pending[].requested

proc clearRequest*(
    self: PendingBlocksManager, address: BlockAddress, peer: ?PeerId = PeerId.none
) =
  self.blocks.withValue(address, pending):
    if peer.isNone or peer == pending[].requested:
      pending[].clearRequestTimeout()
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
