## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/tables
import std/monotimes
import std/hashes
import std/heapqueue
import std/sequtils
import std/sets
import std/strformat

import pkg/chronos
import pkg/libp2p
import pkg/questionable
import pkg/metrics
import pkg/results

import ../protobuf/blockexc
import ../peers/peerctxstore
import ../peers/peercontext
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
  DefaultMaxBatchBlocks* = 256
  DefaultMaxBatchBlocksTimeout* = 1.millis
  DefaultBlockRetries* = 3000
  DefaultRequestTimeout* = 10.seconds
  DefaultDiscoveryWaitTimeout = 5.seconds
  DefaultBlockSendRetryDelay* = 500.millis
  DefaultYieldInterval = 20.millis

type
  BlockHandle* = Future[BlockDelivery].Raising([CancelledError, EngineError])

  AbandonHandler* =
    proc(address: BlockAddress) {.gcsafe, async: (raises: [CancelledError]).}

  TimeoutHandler* = proc(address: BlockAddress, peer: PeerId) {.
    gcsafe, async: (raises: [CancelledError])
  .}

  BatchSendHandler* = proc(
    peer: BlockExcPeerCtx, batch: seq[BlockAddress]
  ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).}

  PeerSelectorHandler* = proc(address: BlockAddress): Future[?!BlockExcPeerCtx] {.
    gcsafe, async: (raises: [CancelledError])
  .}

  BlockReqState = enum
    Pending
    Dispatching
    Scheduled
    InFlight

  BlockReq = ref object
    handle: BlockHandle
    address: BlockAddress
    owners: HashSet[BlockHandle]
    state: BlockReqState
    requestedPeer: BlockExcPeerCtx # nil = unassigned
    requestTimeout: Future[void]
    startTime: int64
    priority: int
    retries: int
    attempts: int
    generation: int
    addedAt: Moment
    readyAt: Moment

  BlockItem = object
    address: BlockAddress
    readyAt: Moment
    addedAt: Moment
    generation: int
    priority: int

  BatchReq = ref object
    peer: BlockExcPeerCtx
    deadline: Future[void]
    pipe: AsyncQueue[BlockAddress]
    workerFut: Future[void].Raising([])
    monitorFut: Future[void].Raising([])

  PendingBlocksManager* = ref object of RootObj
    blocks: Table[BlockAddress, BlockReq]
    handles: Table[BlockHandle, BlockAddress]
    blockQueue: HeapQueue[BlockItem]
    byPeer: Table[PeerId, BatchReq]
    queueWakeEvent: AsyncEvent
    lastInclusion*: Moment
    batchSize: int
    batchDeadline: Duration
    discoveryTimeout: Duration
    blockSendTimeout*: Duration
    retries = DefaultBlockRetries
    running: bool
    trackedFutures: TrackedFutures
    yieldInterval: Duration

    onAbandon*: AbandonHandler
    onTimeout*: TimeoutHandler
    sendBatch*: BatchSendHandler
    getPeerForBlock*: PeerSelectorHandler

func hash(handle: BlockHandle): Hash =
  cast[pointer](handle).hash

func `<`(a, b: BlockItem): bool =
  if a.readyAt != b.readyAt:
    return a.readyAt < b.readyAt
  if a.priority != b.priority:
    return a.priority > b.priority # higher numeric = higher priority
  a.addedAt < b.addedAt

proc updatePendingBlockGauge(p: PendingBlocksManager) =
  archivist_block_exchange_pending_block_requests.set(p.blocks.len.int64)

func owners*(self: PendingBlocksManager, address: BlockAddress): int =
  if pending =? self.blocks .? [address]: pending.owners.len else: 0

func owners*(self: PendingBlocksManager, cid: Cid): int =
  self.owners(BlockAddress.init(cid))

func retries*(self: PendingBlocksManager, address: BlockAddress): int =
  if pending =? self.blocks .? [address]: pending.retries else: 0

func decRetries*(self: PendingBlocksManager, address: BlockAddress) =
  if pending =? self.blocks .? [address]:
    pending.retries -= 1

func retriesExhausted*(self: PendingBlocksManager, address: BlockAddress): bool =
  if pending =? self.blocks .? [address]:
    return pending.retries <= 0
  false

func isRequested*(self: PendingBlocksManager, address: BlockAddress): bool =
  if pending =? self.blocks .? [address]:
    return pending.requestedPeer != nil
  false

func isFirstAttempt*(self: PendingBlocksManager, address: BlockAddress): bool =
  if pending =? self.blocks .? [address]:
    return pending.retries == self.retries
  false

func getRequestPeerCtx*(
    self: PendingBlocksManager, address: BlockAddress
): BlockExcPeerCtx =
  if pending =? self.blocks .? [address]:
    return pending.requestedPeer
  nil

func getRequestPeerCtx*(
    self: PendingBlocksManager, handle: BlockHandle
): BlockExcPeerCtx =
  if address =? self.handles .? [handle]:
    return self.getRequestPeerCtx(address)
  nil

func getRequestPeer*(self: PendingBlocksManager, address: BlockAddress): ?PeerId =
  let peer = self.getRequestPeerCtx(address)
  if peer != nil:
    return peer.id.some
  PeerId.none

func getRequestPeer*(self: PendingBlocksManager, handle: BlockHandle): ?PeerId =
  if address =? self.handles .? [handle]:
    return self.getRequestPeer(address)
  PeerId.none

func getHandleAddress*(self: PendingBlocksManager, handle: BlockHandle): ?BlockAddress =
  if address =? self.handles .? [handle]:
    return address.some
  return BlockAddress.none

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

proc retryAddresses*(
  self: PendingBlocksManager,
  addresses: seq[BlockAddress],
  delay: Duration = DefaultBlockSendRetryDelay,
) {.async: (raises: []).}

proc clearPeerAssignment(
    self: PendingBlocksManager, address: BlockAddress
) {.async: (raises: []).} =
  if req =? self.blocks .? [address]:
    let
      timeoutFut = req.requestTimeout
      assignedPeer = req.requestedPeer

    # Detach synchronously - no other async task can observe stale state
    req.requestTimeout = nil
    req.requestedPeer = nil
    req.state = Pending
    if assignedPeer != nil:
      trace "Clearing peer assignment for block", address, peer = assignedPeer.id
      assignedPeer.blockRequestCleared(address)

    # Now safely cancel the timeout monitor
    if timeoutFut != nil:
      await noCancel timeoutFut.cancelAndWait()

proc releaseWantHandle(
    self: PendingBlocksManager, wrapped: BlockHandle
): Future[?!void] {.async: (raises: []), gcsafe.} =
  if address =? self.handles .? [wrapped]:
    self.handles.del(wrapped)
    if req =? self.blocks .? [address]:
      req.owners.excl(wrapped)
      if req.owners.len == 0:
        if not req.handle.finished:
          warn "Abandoning block", address
          req.handle.fail(
            newException(RequestAbandonedEngineError, fmt"Abandoning block {address}")
          )

          if not self.onAbandon.isNil:
            trace "Handle abandoned, running on abandon hook", address
            await noCancel self.onAbandon(address)
          await self.clearPeerAssignment(address)

      self.queueWakeEvent.fire()
      return success()

  failure("Unable to find block handle")

proc addOwner(
    self: PendingBlocksManager, address: BlockAddress, priority = 0
): BlockHandle {.gcsafe.} =
  if pending =? self.blocks .? [address]:
    let wrapped = pending.handle.wrap()

    pending.owners.incl(wrapped)
    self.handles[wrapped] = address

    proc wrappedMonitor(): Future[void] {.gcsafe, async: (raises: []).} =
      try:
        discard await wrapped
      except CatchableError as exc:
        trace "Exception monitoring wrapper blockhandle", address, exc = exc.msg

      if err =? (await self.releaseWantHandle(wrapped)).errorOption:
        trace "Unable to release handle", address, err = err.msg

    if priority > pending.priority:
      pending.priority = priority

    self.trackedFutures.track(wrappedMonitor())
    pending.generation.inc()
    let now = Moment.now()
    self.blockQueue.push(
      BlockItem(
        address: address,
        readyAt: pending.readyAt,
        addedAt: now,
        generation: pending.generation,
        priority: pending.priority,
      )
    )

    self.queueWakeEvent.fire()
    return wrapped

  raiseAssert "Pending block missing while adding owner"

proc getWantHandle*(
    self: PendingBlocksManager, address: BlockAddress, priority = 0
): BlockHandle =
  if address notin self.blocks:
    let handle = BlockHandle.init("pendingBlocks.sharedHandle")
    let now = Moment.now()
    self.blocks[address] = BlockReq(
      address: address,
      handle: handle,
      retries: self.retries,
      startTime: getMonoTime().ticks,
      priority: priority,
      addedAt: now,
      readyAt: now,
      state: Pending,
    )
    self.lastInclusion = now
    self.updatePendingBlockGauge()

    proc handleMonitor() {.async: (raises: []).} =
      try:
        discard await handle
      except CatchableError as exc:
        trace "Exception in handle monitor", exc = exc.msg

      if req =? self.blocks .? [address]:
        await self.clearPeerAssignment(address)

      self.blocks.del(address)
      self.updatePendingBlockGauge()

    self.trackedFutures.track(handleMonitor())

  return self.addOwner(address, priority)

proc getWantHandle*(self: PendingBlocksManager, cid: Cid): BlockHandle =
  self.getWantHandle(BlockAddress.init(cid))

proc resolve*(
    self: PendingBlocksManager, blocksDelivery: seq[BlockDelivery]
) {.async: (raises: [CancelledError]).} =
  for bd in blocksDelivery:
    if blockReq =? self.blocks .? [bd.address]:
      if not blockReq.handle.finished:
        trace "Resolving pending block", address = bd.address
        let
          startTime = blockReq.startTime
          stopTime = getMonoTime().ticks
          retrievalDurationUs = (stopTime - startTime) div 1000

        await self.clearPeerAssignment(bd.address)
        if not blockReq.handle.finished:
          blockReq.handle.complete(bd)

        archivist_block_exchange_retrieval_time_us.set(retrievalDurationUs)

        if retrievalDurationUs > 500000:
          trace "High block retrieval time", retrievalDurationUs, address = bd.address
      else:
        trace "Block handle already finished", address = bd.address

proc resolve*(
    self: PendingBlocksManager, address: BlockAddress, blk: Block
) {.async: (raises: [CancelledError]).} =
  await self.resolve(@[BlockDelivery(blk: blk, address: address)])

proc failOwners(
    self: PendingBlocksManager, address: BlockAddress, err: ref EngineError
) {.gcsafe.} =
  if req =? self.blocks .? [address]:
    for wrapped in req.owners:
      if not wrapped.finished:
        wrapped.fail(err)

proc failWantHandle*(
    self: PendingBlocksManager,
    address: BlockAddress,
    errType: typedesc[EngineError],
    msg: string,
) {.async: (raises: []).} =
  if blockReq =? self.blocks .? [address]:
    if not blockReq.handle.finished:
      await self.clearPeerAssignment(address)
      let err = (ref errType)(address: address, msg: msg)
      blockReq.handle.fail(err)
      self.failOwners(address, err)

proc markRequested*(
    self: PendingBlocksManager,
    address: BlockAddress,
    peer: BlockExcPeerCtx,
    timeout: Duration = DefaultRequestTimeout,
) =
  if pending =? self.blocks .? [address]:
    if pending.requestedPeer != nil and pending.state == InFlight:
      trace "Block already requested", address, requestedPeer = pending.requestedPeer.id
      return

    pending.requestedPeer = peer
    pending.state = InFlight
    pending.retries -= 1
    peer.blockRequestScheduled(address)

    let handle = pending.handle
    var currentMonitor: Future[void].Raising([])
    proc timeoutMonitor() {.async: (raises: []).} =
      let timeoutFut = sleepAsync(timeout)
      try:
        await handle or timeoutFut
        let reqPeer = self.getRequestPeerCtx(address).option
        if reqPeer != peer.option:
          trace "Requested and timed out peers don't match",
            oldPeer = peer.id, newPeer = reqPeer .? id, address
          return
      except CatchableError as exc:
        trace "Exception in request timeout monitor", exc = exc.msg
      finally:
        await noCancel timeoutFut.cancelAndWait()

      if handle.finished:
        trace "Exiting timeout monitor, handle finished", address, peer = peer.id
        return

      if timeoutFut.completed:
        # Requeue the block for retry before notifying the engine.
        # Only if we still own the assignment (no concurrent clear/resolve).
        if req =? self.blocks .? [address]:
          if req.requestTimeout == currentMonitor and req.requestedPeer == peer:
            req.requestedPeer.blockRequestCleared(address)
            req.requestedPeer = nil
            req.requestTimeout = nil
            await self.retryAddresses(@[address], 0.millis)

        if not self.onTimeout.isNil:
          trace "Timeout elapsed, calling onTimeout callback", peer = peer.id, address
          await noCancel self.onTimeout(address, peer.id)

    currentMonitor = timeoutMonitor()
    pending.requestTimeout = currentMonitor
    self.trackedFutures.track(currentMonitor)

proc clearRequest*(
    self: PendingBlocksManager, address: BlockAddress
) {.async: (raises: []).} =
  await self.clearPeerAssignment(address)

proc clearRequest*(
    self: PendingBlocksManager, address: BlockAddress, peer: BlockExcPeerCtx
) {.async: (raises: []).} =
  if req =? self.blocks .? [address]:
    if req.requestedPeer == peer:
      await self.clearPeerAssignment(address)

proc retryAddresses*(
    self: PendingBlocksManager,
    addresses: seq[BlockAddress],
    delay: Duration = DefaultBlockSendRetryDelay,
) {.async: (raises: []).} =
  for address in addresses:
    trace "Retrying address", address

    without req =? self.blocks .? [address]:
      continue

    if req.state == Dispatching:
      continue

    await self.clearPeerAssignment(address)

    req.state = Pending
    req.generation.inc()
    req.readyAt = Moment.now() + delay
    self.blockQueue.push(
      BlockItem(
        address: address,
        readyAt: req.readyAt,
        addedAt: req.addedAt,
        generation: req.generation,
        priority: req.priority,
      )
    )

  self.queueWakeEvent.fire()

proc validateBlock(
    self: PendingBlocksManager, address: BlockAddress
): Future[bool] {.async: (raises: [CancelledError]).} =
  without req =? self.blocks .? [address]:
    trace "Address is not pending", address
    return false

  if req.state in {Dispatching, InFlight}:
    trace "Address already in pipeline, skipping", address, state = req.state
    return false

  if self.retriesExhausted(address):
    trace "Retries exhausted, skipping block", address
    await self.failWantHandle(
      address, RetriesExhaustedEngineError, "Block request retries exhausted"
    )
    return false

  return true

proc peerBatchWorker(
    self: PendingBlocksManager, batchReq: BatchReq
) {.async: (raises: []).} =
  defer:
    # make sure to drain the queue if we're exiting
    # while the engine is still running
    if self.running and not batchReq.pipe.empty():
      await self.retryAddresses(batchReq.pipe.toSeq, self.blockSendTimeout)

  try:
    while self.running:
      var batch: seq[BlockAddress] = @[]

      # Get first item (blocking wait)
      let first = await batchReq.pipe.get()
      trace "Scheduling peer block", address = first, peer = batchReq.peer.id

      if not await self.validateBlock(first):
        trace "Block validation failed", address = first
        continue

      batch.add(first)

      batchReq.deadline = sleepAsync(self.batchDeadline)
      defer:
        await noCancel batchReq.deadline.cancelAndWait()

      while batch.len < self.batchSize:
        if batchReq.deadline.finished:
          trace "Deadline expired", batch = batch.len
          break

        let next = batchReq.pipe.get()
        try:
          await next or batchReq.deadline
        except CatchableError as exc:
          trace "Exception awaiting queue item", exc = exc.msg
          if batch.len > 0:
            await self.retryAddresses(batch, self.blockSendTimeout)
          raise exc
        finally:
          await noCancel next.cancelAndWait()

        if not next.completed:
          trace "Skipping incomplete queue item"
          continue

        let address = await next
        if not await self.validateBlock(address):
          trace "Block validation failed", address
          continue

        batch.add(address)

      trace "Dispatching batch to peer", peer = batchReq.peer.id, batch = batch.len

      for address in batch:
        self.markRequested(address, batchReq.peer)

      if not self.sendBatch.isNil and batch.len > 0:
        if err =? (await self.sendBatch(batchReq.peer, batch)).errorOption:
          warn "Batch send failed", peer = batchReq.peer.id, err = err.msg
          await self.retryAddresses(batch, self.blockSendTimeout)
  except CatchableError as exc:
    trace "Exception in peer batch worker", exc = exc.msg

proc pushPeerBlock(
    self: PendingBlocksManager, address: BlockAddress
) {.async: (raises: []).} =
  try:
    without req =? self.blocks .? [address]:
      trace "Address not in blocks", address
      return

    if req.state in {Scheduled, InFlight}:
      trace "Address already in pipeline", address, state = req.state
      return

    if self.retriesExhausted(address):
      trace "Retries exhausted, skipping block", address
      await self.failWantHandle(
        address, RetriesExhaustedEngineError, "Block request retries exhausted"
      )
      return

    if self.getPeerForBlock.isNil:
      trace "No peer selector configured", address
      return

    without peer =? await self.getPeerForBlock(address), err:
      trace "Unable to get peer", address, err = err.msg
      if err of NoPeerForBlockError:
        req.state = Pending
        await self.retryAddresses(@[address], self.discoveryTimeout)
      return

    var batchReq: BatchReq
    self.byPeer.withValue(peer.id, existing):
      batchReq = existing[]
    do:
      trace "Creating new peer request worker", peer = peer.id
      batchReq = BatchReq(peer: peer, pipe: newAsyncQueue[BlockAddress](self.batchSize))
      self.byPeer[peer.id] = batchReq
      batchReq.workerFut = self.peerBatchWorker(batchReq)
      self.trackedFutures.track(batchReq.workerFut)

      # Register disconnect monitor on first use of this peer
      proc disconnectMonitor() {.async: (raises: []).} =
        try:
          trace "Monitoring peer disconnect", peer = peer.id
          await peer.onDisconnect()
        except CatchableError as exc:
          trace "Exception in disconnect monitor", exc = exc.msg

        trace "Peer disconnected, performing cleanup", peer = peer.id
        await noCancel batchReq.workerFut.cancelAndWait()
        # Requeue all blocks assigned to this peer

        let
          blocks = peer.blocksRequested.toSeq
          (_, failed) = await noCancel allFinishedFailed[void](
            blocks.mapIt(self.clearPeerAssignment(it))
          )

        if failed.len > 0:
          trace "Not all blocks peer assignments were cleared", failed = failed.len

        if blocks.len > 0:
          await self.retryAddresses(blocks, self.discoveryTimeout)

        # Clean up byPeer entry
        self.byPeer.del(peer.id)

      batchReq.monitorFut = disconnectMonitor()
      self.trackedFutures.track(batchReq.monitorFut)

    req.state = Scheduled
    req.requestedPeer = batchReq.peer
    batchReq.peer.blockRequestScheduled(address)
    await batchReq.pipe.put(address)
  except CatchableError as exc:
    trace "Exception pushing block to peer worker", address, exc = exc.msg

proc blockRequestScheduler(self: PendingBlocksManager) {.async: (raises: []).} =
  try:
    var nextYield = Moment.now() + self.yieldInterval
    while self.running:
      if self.blockQueue.len == 0:
        await self.queueWakeEvent.wait()
        self.queueWakeEvent.clear()
        continue

      let
        item = self.blockQueue[0]
        now = Moment.now()

      if item.readyAt > now:
        let timer = sleepAsync(item.readyAt - now)
        await timer or self.queueWakeEvent.wait()
        await noCancel timer.cancelAndWait()
        self.queueWakeEvent.clear()
        continue

      let
        blockReq = self.blockQueue.pop()
        address = blockReq.address

      without req =? self.blocks .? [address], err:
        trace "Request don't seem to exist", err = err.msg
        continue

      if blockReq.generation != req.generation:
        trace "Block generation don't match, stale block", address
        continue

      req.state = Dispatching
      # We need to spawn a task, because pushPeerBlock
      # might need to await for peers and we don't want
      # to hold up the dispatch loop
      self.trackedFutures.track(self.pushPeerBlock(address))

      # TODO: This needs to be changed sleep/idleAsync
      # after some budget has been consumed
      if Moment.now() > nextYield:
        nextYield = Moment.now() + self.yieldInterval
        trace "Yielding in scheduler loop",
          nextYield = nextYield, interval = self.yieldInterval
        await sleepAsync(0.millis)
  except CatchableError as exc:
    trace "Exception in block request scheduler", err = exc.msg

proc start*(self: PendingBlocksManager) {.async: (raises: []).} =
  if self.running:
    trace "Block scheduler already running"
    return

  self.running = true
  self.trackedFutures.track(self.blockRequestScheduler())

proc stop*(self: PendingBlocksManager) {.async: (raises: []).} =
  if not self.running:
    trace "Block scheduler not running"

  self.running = false
  self.queueWakeEvent.fire()

  self.blockQueue.clear()
  self.byPeer.clear()

  var handles: seq[BlockHandle]
  for req in self.blocks.values:
    handles.add(req.handle)
    for owner in req.owners:
      handles.add(owner)

  let cancellations = handles.mapIt(it.cancelAndWait())
  await noCancel allFutures(cancellations)

  self.handles.clear()
  self.blocks.clear()
  self.updatePendingBlockGauge()

  await noCancel self.trackedFutures.cancelTracked()

func new*(
    T: type PendingBlocksManager,
    retries = DefaultBlockRetries,
    batchSize = DefaultMaxBatchBlocks,
    batchDeadline = DefaultMaxBatchBlocksTimeout,
    discoveryTimeout = DefaultDiscoveryWaitTimeout,
    blockSendTimeout = DefaultBlockSendRetryDelay,
    yieldInterval = DefaultYieldInterval,
    sendBatch: BatchSendHandler = nil,
    onAbandon: AbandonHandler = nil,
    onTimeout: TimeoutHandler = nil,
    getPeerForBlock: PeerSelectorHandler = nil,
): PendingBlocksManager =
  PendingBlocksManager(
    retries: retries,
    batchSize: batchSize,
    batchDeadline: batchDeadline,
    discoveryTimeout: discoveryTimeout,
    blockSendTimeout: blockSendTimeout,
    trackedFutures: TrackedFutures.new(),
    queueWakeEvent: newAsyncEvent(),
    yieldInterval: yieldInterval,
    sendBatch: sendBatch,
    getPeerForBlock: getPeerForBlock,
    onAbandon: onAbandon,
    onTimeout: onTimeout,
  )
