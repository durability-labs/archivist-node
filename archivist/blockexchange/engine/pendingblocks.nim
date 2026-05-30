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
import std/sequtils
import std/sets
import std/strformat
import std/enumutils

import pkg/chronos
import pkg/libp2p
import pkg/questionable
import ./metrics
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

const
  DefaultMaxBatchBlocks* = 128
  DefaultMaxBatchBlocksDeadline* = 50.millis
  DefaultBlockRetries* = 3000
  DefaultDiscoveryWaitTimeout = 5.seconds

type
  PeerSelectionKind* {.pure.} = enum
    Peer
    Requeue

  ## delay == 0.seconds means "no wake hint; use discoveryTimeout backstop"
  PeerSelection* = object
    case kind*: PeerSelectionKind
    of PeerSelectionKind.Peer:
      peer*: BlockExcPeerCtx
    of PeerSelectionKind.Requeue:
      delay*: Duration

  BlockHandle* = Future[BlockDelivery].Raising([CancelledError, EngineError])

  AbandonHandler* =
    proc(address: BlockAddress) {.gcsafe, async: (raises: [CancelledError]).}

  TimeoutHandler* = proc(address: BlockAddress, peer: PeerId) {.
    gcsafe, async: (raises: [CancelledError])
  .}

  BatchSendHandler* = proc(
    peer: BlockExcPeerCtx, batch: seq[BlockAddress]
  ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).}

  PeerSelectorHandler* = proc(address: BlockAddress): Future[?!PeerSelection] {.
    async: (raises: [CancelledError]), gcsafe
  .}

  RetryReason* {.pure.} = enum
    Timeout = "timeout"
    NoPeer = "no_peer"
    Presence = "presence"
    Disconnect = "disconnect"
    SendError = "send_error"
    Validation = "validation"

  NoPeerAttempt* {.pure.} = enum
    First = "first"
    Subsequent = "subsequent"

  BlockReq = ref object
    handle: BlockHandle
    address: BlockAddress
    owners: HashSet[BlockHandle]
    requestedPeer: BlockExcPeerCtx # nil = unassigned
    startTime: int64
    stateEnteredAt: int64
    priority: int
    retries: int
    attempts: int
    noPeerFirstAttempted: bool
    addedAt: Moment
    dispatchFut: Future[void].Raising([])
    dispatched: AsyncEvent
    wakeEvent: AsyncEvent

  BatchReq = object
    peer: BlockExcPeerCtx
    deadline: Future[void]
    pipe: AsyncQueue[BlockReq]
    workerFut: Future[void].Raising([])
    monitorFut: Future[void].Raising([])

  PendingBlocksManager* = ref object of RootObj
    blocks: Table[BlockAddress, BlockReq]
    handles: Table[BlockHandle, BlockAddress]
    byPeer: Table[PeerId, BatchReq]
    batchSize: int
    batchDeadline: Duration
    discoveryTimeout: Duration
    blockSendTimeout*: Duration
    retries = DefaultBlockRetries
    running: bool
    trackedFutures: TrackedFutures

    onAbandon*: AbandonHandler
    onTimeout*: TimeoutHandler
    sendBatch*: BatchSendHandler
    getPeerForBlock*: PeerSelectorHandler

func hash(handle: BlockHandle): Hash =
  cast[pointer](handle).hash

proc recordRetryOutcome*(self: PendingBlocksManager, addresses: seq[BlockAddress]) =
  ## Record outcome duration for retried blocks
  let now = getMonoTime().ticks
  for address in addresses:
    if req =? self.blocks .? [address]:
      let durationUs = (now - req.startTime) div 1000
      archivist_block_exchange_request_outcome_duration_seconds.observe(
        durationUs.float64 / 1_000_000, labelValues = ["retried"]
      )

proc recordRetryOutcome*(self: PendingBlocksManager, addresses: seq[BlockAddress]) =
  ## Record outcome duration for retried blocks
  let now = getMonoTime().ticks
  for address in addresses:
    if req =? self.blocks .? [address]:
      let durationUs = (now - req.startTime) div 1000
      archivist_block_exchange_request_outcome_duration_seconds.observe(
        durationUs.float64 / 1_000_000, labelValues = ["retried"]
      )

proc updatePendingBlockGauge(p: PendingBlocksManager) =
  archivist_block_exchange_pending_block_requests.set(p.blocks.len.int64)

func owners*(self: PendingBlocksManager, address: BlockAddress): int =
  if pending =? self.blocks .? [address]: pending.owners.len else: 0

func owners*(self: PendingBlocksManager, cid: Cid): int =
  self.owners(BlockAddress.init(cid))

func retries*(self: PendingBlocksManager, address: BlockAddress): int =
  if pending =? self.blocks .? [address]: pending.retries else: 0

func decRetries*(self: PendingBlocksManager, address: BlockAddress) =
  if var pending =? self.blocks .? [address]:
    pending.retries -= 1

func retriesExhausted*(self: PendingBlocksManager, address: BlockAddress): bool =
  if pending =? self.blocks .? [address]:
    return pending.retries <= 0
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

func isRequested*(self: PendingBlocksManager, address: BlockAddress): bool =
  if pending =? self.blocks .? [address]:
    return pending.requestedPeer != nil
  false

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

proc blockDispatchMonitor(
  self: PendingBlocksManager, req: BlockReq
) {.async: (raises: []).}

proc releaseWantHandle(
    self: PendingBlocksManager, wrapped: BlockHandle
): Future[?!void] {.async: (raises: []), gcsafe.} =
  without address =? self.handles .? [wrapped]:
    return failure("Unable to find block handle")

  self.handles.del(wrapped)

  without req =? self.blocks .? [address]:
    return success()

  req.owners.excl(wrapped)
  if req.owners.len == 0 and not req.handle.finished:
    warn "Abandoning block", address
    archivist_block_exchange_requests_abandoned.inc()
    let now = getMonoTime().ticks
    let durationUs = (now - req.startTime) div 1000
    archivist_block_exchange_request_outcome_duration_seconds.observe(
      durationUs.float64 / 1_000_000, labelValues = ["abandoned"]
    )
    archivist_block_exchange_handles_failed.inc()

    req.handle.fail(
      newException(RequestAbandonedEngineError, fmt"Abandoning block {address}")
    )

    if not self.onAbandon.isNil:
      trace "Handle abandoned, running on abandon hook", address
      await noCancel self.onAbandon(address)

    if not req.dispatchFut.isNil:
      await noCancel req.dispatchFut.cancelAndWait()

  return success()

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
        archivist_block_exchange_handles_missing_on_release.inc()
        trace "Unable to release handle", address, err = err.msg

    self.trackedFutures.track(wrappedMonitor())
    if priority > pending.priority:
      pending.priority = priority

    return wrapped

  raiseAssert "Pending block missing while adding owner"

proc getWantHandle*(
    self: PendingBlocksManager, address: BlockAddress, priority = 0
): BlockHandle =
  if not self.running:
    raiseAssert "PendingBlocksManager should be started before calling getWantHandle()"
  ## Create a handle for the block
  ##

  if address notin self.blocks:
    let
      handle = BlockHandle.init("pendingBlocks.sharedHandle")
      now = Moment.now()

    trace "Creating handle for block", address
    archivist_block_exchange_handles_created.inc()
    let req = BlockReq(
      address: address,
      handle: handle,
      retries: self.retries,
      startTime: getMonoTime().ticks,
      stateEnteredAt: getMonoTime().ticks,
      priority: priority,
      addedAt: now,
      dispatched: newAsyncEvent(),
      wakeEvent: newAsyncEvent(),
    )

    self.blocks[address] = req
    proc handleMonitor() {.async: (raises: []).} =
      try:
        discard await handle
      except CatchableError as exc:
        trace "Exception in handle monitor", exc = exc.msg

      self.blocks.del(address)
      await noCancel req.dispatchFut.cancelAndWait()
      self.updatePendingBlockGauge()

    self.trackedFutures.track(handleMonitor())
    req.dispatchFut = self.blockDispatchMonitor(req)
    self.trackedFutures.track(req.dispatchFut)

  return self.addOwner(address, priority)

proc getWantHandle*(self: PendingBlocksManager, cid: Cid): BlockHandle =
  self.getWantHandle(BlockAddress.init(cid))

proc resolve*(
    self: PendingBlocksManager,
    blocksDelivery: seq[BlockDelivery],
    sender = BlockExcPeerCtx.none,
) {.async: (raises: [CancelledError]).} =
  for bd in blocksDelivery:
    without blockReq =? self.blocks .? [bd.address]:
      trace "Block handle already finished", address = bd.address
      continue

    if not blockReq.handle.finished:
      trace "Resolving pending block", address = bd.address, sender = sender .? id
      let
        startTime = blockReq.startTime
        stopTime = getMonoTime().ticks
        retrievalDurationUs = (stopTime - startTime) div 1000
        assignedPeer = blockReq.requestedPeer

      if blockReq.handle.finished:
        trace "Block handle already finished, skipping",
          address = bd.address, sender = sender .? id
        continue

      blockReq.handle.complete(bd)
      archivist_block_exchange_requests_succeeded.inc()
      archivist_block_exchange_handles_resolved.inc()
      archivist_block_exchange_retrieval_duration_seconds.observe(
        retrievalDurationUs.float64 / 1_000_000
      )

      # Clear peer assignment synchronously so cancelBlocks doesn't
      # send redundant cancellations to the assigned peer. The monitor's
      # defer is a safety net for non-resolve exit paths.
      if not assignedPeer.isNil:
        assignedPeer.blockRequestCleared(bd.address)
        blockReq.requestedPeer = nil

      # Record delivery for the assigned peer. Deliveries
      # for mismatched peers (late deliveries) are not recorded
      # for neither the sender nor the currently requested peer.
      if senderPeer =? sender and senderPeer == assignedPeer:
        let latencyMs = float(retrievalDurationUs) / 1000.0
        assignedPeer.recordDelivery(bd.address, bd.blk.data.len, latencyMs)

      archivist_block_exchange_retrieval_duration_seconds.observe(
        retrievalDurationUs.float64 / 1_000_000
      )
      if retrievalDurationUs > 500000:
        trace "High block retrieval time", retrievalDurationUs, address = bd.address

proc resolve*(
    self: PendingBlocksManager, address: BlockAddress, blk: Block
) {.async: (raises: [CancelledError]).} =
  await self.resolve(
    @[BlockDelivery(blk: blk, address: address)], none(BlockExcPeerCtx)
  )

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
      let err = (ref errType)(address: address, msg: msg)
      blockReq.handle.fail(err)
      archivist_block_exchange_handles_failed.inc()
      let now = getMonoTime().ticks
      let durationUs = (now - blockReq.startTime) div 1000
      archivist_block_exchange_request_outcome_duration_seconds.observe(
        durationUs.float64 / 1_000_000, labelValues = ["failed"]
      )
      self.failOwners(address, err)

proc markRequested*(
    self: PendingBlocksManager, address: BlockAddress, peer: BlockExcPeerCtx
) =
  if pending =? self.blocks .? [address]:
    if pending.requestedPeer != nil:
      trace "Block already requested", address, requestedPeer = pending.requestedPeer.id
      return

    pending.requestedPeer = peer
    pending.retries -= 1
    peer.blockRequestScheduled(address)

proc rejectRequest*(
    self: PendingBlocksManager, address: BlockAddress, peer: BlockExcPeerCtx
): bool =
  ## Reject an in-flight request: clear assignment and fire wakeEvent.
  ## Returns true if the request was rejected.
  if req =? self.blocks .? [address]:
    if not req.handle.finished and req.requestedPeer == peer:
      peer.blockRequestCleared(address)
      req.requestedPeer = nil
      req.wakeEvent.fire()
      req.wakeEvent.clear()
      return true

  return false

proc wakeAddress*(self: PendingBlocksManager, address: BlockAddress): bool =
  ## Pulse wakeEvent for an unassigned, unfinished request.
  ## Returns true only when the pulse was delivered (request exists,
  ## is unfinished, and has no assigned peer).
  if req =? self.blocks .? [address]:
    if not req.handle.finished and req.requestedPeer.isNil:
      req.wakeEvent.fire()
      req.wakeEvent.clear()
      return true

  return false

proc shouldSkipBatch(self: PendingBlocksManager, item: BlockReq): bool =
  # Skip if BlockReq is missing or handle already finished
  if req =? self.blocks .? [item.address]:
    if req.handle.finished:
      trace "Block already resolved, skipping", address = item.address
      return true
  else:
    trace "Address not in blocks", address = item.address
    return true

  if self.retriesExhausted(item.address):
    trace "Retries exhausted, skipping block", address = item.address
    return true

proc validateBlock(
    self: PendingBlocksManager, address: BlockAddress, state: BlockReqState
): Future[bool] {.async: (raises: [CancelledError]).} =
  without req =? self.blocks .? [address]:
    trace "Address is not pending", address
    return false

  if req.state != state or not req.requestedPeer.isNil:
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
  var batch: seq[BlockReq] = @[]

  defer:
    # Delete byPeer entry only when it still maps to this exact batchReq;
    # an old context must not delete its replacement.
    self.byPeer.withValue(batchReq.peer.id, existing):
      if existing[] == batchReq:
        self.byPeer.del(batchReq.peer.id)

  try:
    while self.running and not batchReq.peer.isDisconnected:
      batch = @[]

      # Race first pipe.get() against disconnect so the idle worker
      # exits without a separate monitor.
      let
        firstFut = batchReq.pipe.get()
        disconnectFut = batchReq.peer.onDisconnect()

      await firstFut or disconnectFut
      await noCancel firstFut.cancelAndWait()
      await noCancel disconnectFut.cancelAndWait()

      if disconnectFut.completed:
        trace "Peer disconnected", peer = batchReq.peer.id
        return

      let first = await firstFut
      trace "Scheduling peer block", address = first.address, peer = batchReq.peer.id

      if self.shouldSkipBatch(first):
        trace "Skipping item from batch",
          peer = batchReq.peer.id, address = first.address
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
        finally:
          await noCancel next.cancelAndWait()

        if not next.completed:
          trace "Skipping incomplete queue item"
          continue

        let item = await next
        if self.shouldSkipBatch(item):
          trace "Skipping item from batch",
            peer = batchReq.peer.id, address = item.address
          continue

        batch.add(item)

      trace "Dispatching batch to peer", peer = batchReq.peer.id, batch = batch.len
      if not self.sendBatch.isNil and batch.len > 0:
        defer:
          for item in batch:
            item.dispatched.fire()
            item.dispatched.clear()

        if err =?
            (await self.sendBatch(batchReq.peer, batch.mapIt(it.address))).errorOption:
          warn "Batch send failed", peer = batchReq.peer.id, err = err.msg
          for cid in batch.mapIt(it.address.cidOrTreeCid).deduplicate:
            batchReq.peer.sendBatchFailure(cid)

          self.recordRetryOutcome(batch.mapIt(it.address))
          continue

        trace "Batch to peer dispatched", peer = batchReq.peer.id, batch = batch.len
        # Success: markRequested post-send, then fire dispatched
        for item in batch:
          self.markRequested(item.address, batchReq.peer)
  except CatchableError as exc:
    trace "Exception in peer batch worker", exc = exc.msg

proc deliver(
    self: PendingBlocksManager, peer: BlockExcPeerCtx, req: BlockReq
): Future[bool] {.async: (raises: [CancelledError]).} =
  ## Push onto peer's queue; return once the batch that carried the address
  ## has been sent. true = sent, false = dropped (caller reselects).
  ##

  if peer.isDisconnected:
    trace "Peer already disconnected, skipping batch request",
      peer = peer.id, address = req.address
    return false

  var batchReq: BatchReq
  var staleWorker: Future[void].Raising([]) = nil
  self.byPeer.withValue(peer.id, existing):
    if existing[].peer == peer:
      batchReq = existing[]
    else:
      staleWorker = existing[].workerFut

  if staleWorker != nil:
    trace "Cancelling stale worker for peer", peer = peer.id
    await noCancel staleWorker.cancelAndWait()

  if batchReq.isNil:
    trace "Creating new peer request worker", peer = peer.id
    batchReq = BatchReq(peer: peer, pipe: newAsyncQueue[BlockReq]())
    self.byPeer[peer.id] = batchReq
    batchReq.workerFut = self.peerBatchWorker(batchReq)
    self.trackedFutures.track(batchReq.workerFut)

  if err =? catch(batchReq.pipe.putNoWait(req)).errorOption:
    trace "Error pushing block to peer batch", err = err.msg
    return false

  let
    disconnected = peer.onDisconnect()
    dispatched = req.dispatched.wait()

  await disconnected or dispatched
  for fut in [disconnected, dispatched]:
    await noCancel fut.cancelAndWait()

  # Evaluate sent-success first: return true even if disconnect also completed.
  if dispatched.completed and req.requestedPeer == peer:
    trace "Dispatch completed",
      expectedPeer = peer.id,
      deliveredPeer = req.requestedPeer.id,
      address = req.address
    return true

  if disconnected.completed:
    trace "Peer disconnected during delivery", peer = peer.id, address = req.address
    # Cancel worker — identity-guarded (defer owns byPeer removal)
    self.byPeer.withValue(peer.id, existing):
      if existing[].peer == peer:
        await noCancel existing[].workerFut.cancelAndWait()

  return false

proc blockDispatchMonitor(
    self: PendingBlocksManager, req: BlockReq
) {.async: (raises: []).} =
  defer:
    if not req.requestedPeer.isNil:
      req.requestedPeer.blockRequestCleared(req.address)
      req.requestedPeer = nil

  try:
    while self.running and not req.handle.finished:
      trace "Processing block", address = req.address, retries = req.retries
      if self.retriesExhausted(req.address):
        await self.failWantHandle(
          req.address, RetriesExhaustedEngineError, "retries exhausted"
        )
        return

      # Install the selection wake waiter before async peer selection.
      let selectionWakeFut = req.wakeEvent.wait()

      without selection =? (await self.getPeerForBlock(req.address)), err:
        trace "Unable to get peer for block", address = req.address, err = err.msg
        defer:
          await noCancel selectionWakeFut.cancelAndWait()

        if selectionWakeFut.finished:
          # A completed wake means peer knowledge changed — reselect now.
          continue

        # No wake — retain discoveryTimeout backoff.
        await sleepAsync(self.discoveryTimeout)
        continue

      case selection.kind
      of PeerSelectionKind.Requeue:
        let delay =
          if selection.delay == 0.seconds:
            self.discoveryTimeout
          else:
            min(selection.delay, self.discoveryTimeout)

        # Race the installed waiter against the clamped delay.
        let delayFut = sleepAsync(delay)
        await selectionWakeFut or delayFut
        trace "Retrying block",
          address = req.address,
          isTimeout = delayFut.completed,
          isWakeup = selectionWakeFut.completed

        await noCancel selectionWakeFut.cancelAndWait()
        await noCancel delayFut.cancelAndWait()
      of PeerSelectionKind.Peer:
        if not await self.deliver(selection.peer, req):
          trace "Unable to send block", peer = selection.peer.id, address = req.address
          if selectionWakeFut.finished:
            # Fresh presence woke during the failed send — reselect now.
            continue

          # Race the wake against the dropped-send backoff.
          let backoffFut = sleepAsync(self.discoveryTimeout)
          await selectionWakeFut or backoffFut
          trace "Retrying block",
            address = req.address,
            isTimeout = backoffFut.completed,
            isWakeup = selectionWakeFut.completed

          await noCancel selectionWakeFut.cancelAndWait()
          await noCancel backoffFut.cancelAndWait()
          continue

        # deliver returned true — sent successfully.
        # Cancel the selection wake; it is no longer needed.
        if not selectionWakeFut.finished:
          await noCancel selectionWakeFut.cancelAndWait()

        # Install the post-send rejection waiter.
        let wakeFut = req.wakeEvent.wait()

        # Synchronously re-check assignment before the next await:
        # a rejection may have run between deliver completion and here.
        if req.requestedPeer != selection.peer:
          await noCancel wakeFut.cancelAndWait()
          continue

        let
          handleFut = req.handle.join()
          timeoutFut = sleepAsync(self.blockSendTimeout)
          disconnectFut = selection.peer.onDisconnect()

        await wakeFut or handleFut or timeoutFut or disconnectFut
        for fut in [wakeFut, handleFut, timeoutFut, disconnectFut]:
          if not fut.finished:
            await noCancel fut.cancelAndWait()

        if req.handle.finished:
          trace "Block handle finished",
            address = req.address, completed = req.handle.completed
          return

        if wakeFut.completed:
          # Rejection — reselect without duplicate scoring/metrics/hooks.
          trace "Block rejected, reselecting", address = req.address
          continue

        block:
          defer:
            # Clear assignment, record one failure, reselect (no onTimeout).
            selection.peer.recordFailure(req.address.cidOrTreeCid)
            selection.peer.blockRequestCleared(req.address)
            req.requestedPeer = nil
            self.recordRetryOutcome(@[req.address])

          if disconnectFut.completed:
            trace "Peer disconnected during in-flight",
              address = req.address, peer = selection.peer.id

            # Cancel worker — identity-guarded (defer owns byPeer removal)
            self.byPeer.withValue(selection.peer.id, existing):
              if existing[].peer == selection.peer:
                await noCancel existing[].workerFut.cancelAndWait()

            continue

          if timeoutFut.completed:
            trace "Block request timed out",
              address = req.address, peer = selection.peer.id

            if not self.onTimeout.isNil:
              await noCancel self.onTimeout(req.address, selection.peer.id)

            continue

        # Should not reach here — one of the futures must have completed.
        trace "Unexpected state in post-send race", address = req.address
  except CancelledError as exc:
    trace "Block dispatch cancelled", err = exc.msg

proc start*(self: PendingBlocksManager) {.async: (raises: []).} =
  if self.running:
    trace "Block scheduler already running"
    return

  self.running = true

proc stop*(self: PendingBlocksManager) {.async: (raises: []).} =
  if not self.running:
    trace "Block scheduler not running"
    return

  self.running = false
  await noCancel self.trackedFutures.cancelTracked()

  self.byPeer.clear()
  self.blocks.clear()
  self.updatePendingBlockGauge()
  self.handles.clear()

func new*(
    T: type PendingBlocksManager,
    retries = DefaultBlockRetries,
    batchSize = DefaultMaxBatchBlocks,
    batchDeadline = DefaultMaxBatchBlocksDeadline,
    discoveryTimeout = DefaultDiscoveryWaitTimeout,
    blockSendTimeout = DefaultRequestTimeout,
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
    sendBatch: sendBatch,
    getPeerForBlock: getPeerForBlock,
    onAbandon: onAbandon,
    onTimeout: onTimeout,
  )
