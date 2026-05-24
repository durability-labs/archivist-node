## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/hashes
import std/options
import std/sequtils
import std/sets
import std/tables

import pkg/chronos
import pkg/libp2p/[cid, switch, multihash, multicodec]
import pkg/metrics
import pkg/questionable
import pkg/results

import ../../rng
import ../../stores/blockstore
import ../../blocktype
import ../../utils
import ../../utils/trackedfutures
import ../../merkletree
import ../../logutils
import ../../manifest

import ../protobuf/blockexc
import ../protobuf/presence

import ../network
import ../peers

import ./discovery
import ./advertiser
import ./errors
import ./pendingblocks

export peers, pendingblocks, discovery, errors

logScope:
  topics = "archivist blockexcengine"

declareCounter(
  archivist_block_exchange_want_have_lists_received,
  "archivist blockexchange wantHave lists received",
)
declareCounter(
  archivist_block_exchange_want_block_lists_sent,
  "archivist blockexchange wantBlock lists sent",
)
declareCounter(
  archivist_block_exchange_want_block_lists_received,
  "archivist blockexchange wantBlock lists received",
)
declareCounter(
  archivist_block_exchange_blocks_sent, "archivist blockexchange blocks sent"
)
declareCounter(
  archivist_block_exchange_blocks_received, "archivist blockexchange blocks received"
)
declareCounter(
  archivist_block_exchange_spurious_blocks_received,
  "archivist blockexchange unrequested/duplicate blocks received",
)
declareCounter(
  archivist_block_exchange_discovery_requests_total,
  "Total number of peer discovery requests sent",
)
declareCounter(
  archivist_block_exchange_peer_timeouts_total, "Total number of peer activity timeouts"
)
declareCounter(
  archivist_block_exchange_requests_failed_total,
  "Total number of block requests that failed after exhausting retries",
)

const
  DefaultTaskQueueSize = 128
  DefaultConcurrentTasks = 3
  DefaultMaxBlocksPerMessage = 128
  DefaultWantBlockBatchSize = 128
  DefaultWantBlockBatchTimeout = 5.millis
  DefaultBlockSendRetryDelay = 500.millis
  DiscoveryRateLimit = 3.seconds
  PresenceBatchSize = DefaultMaxWantListBatchSize
  CleanupBatchSize = 2048

type
  TaskHandler* = proc(task: BlockExcPeerCtx): Future[void] {.gcsafe.}
  TaskScheduler* = proc(task: BlockExcPeerCtx): bool {.gcsafe.}
  PeerSelector* =
    proc(peers: seq[BlockExcPeerCtx]): BlockExcPeerCtx {.gcsafe, raises: [].}

  BlockExcEngine* = ref object of RootObj
    localStore*: BlockStore
    network*: BlockExcNetwork
    peers*: PeerCtxStore
    taskQueue*: AsyncHeapQueue[BlockExcPeerCtx]
    selectPeer*: PeerSelector
    concurrentTasks: int
    trackedFutures: TrackedFutures
    blockexcRunning: bool
    maxBlocksPerMessage: int
    wantBlockBatchSize: int
    wantBlockBatchTimeout: Duration
    discoveryDeadline*: Duration
    blockRequestTimeout: Duration
    pendingBlocks*: PendingBlocksManager
    discovery*: DiscoveryEngine
    advertiser*: Advertiser
    lastDiscRequest: Moment

proc scheduleTask(self: BlockExcEngine, task: BlockExcPeerCtx) {.gcsafe, raises: [].} =
  if self.taskQueue.pushOrUpdateNoWait(task).isOk():
    trace "Task scheduled for peer", peer = task.id
  else:
    warn "Unable to schedule task for peer", peer = task.id

proc blockexcTaskRunner(self: BlockExcEngine) {.async: (raises: []).}
proc blockRequestScheduler(self: BlockExcEngine) {.async: (raises: []).}
proc resolveBlocks*(
  self: BlockExcEngine, blocksDelivery: seq[BlockDelivery]
) {.async: (raises: [CancelledError]).}

proc start*(self: BlockExcEngine) {.async: (raises: []).} =
  trace "Blockexc starting with concurrent tasks", tasks = self.concurrentTasks
  if self.blockexcRunning:
    warn "Starting blockexc twice"
    return

  self.blockexcRunning = true

  await self.discovery.start()
  await self.advertiser.start()

  for i in 0 ..< self.concurrentTasks:
    self.trackedFutures.track(self.blockexcTaskRunner())

  self.trackedFutures.track(self.blockRequestScheduler())

proc stop*(self: BlockExcEngine) {.async: (raises: []).} =
  if not self.blockexcRunning:
    warn "Stopping blockexc without starting it"
    return

  self.blockexcRunning = false
  await self.trackedFutures.cancelTracked()
  await self.pendingBlocks.cancelAll()
  await self.network.stop()
  await self.discovery.stop()
  await self.advertiser.stop()

proc sendWantBlock(
    self: BlockExcEngine, addresses: seq[BlockAddress], blockPeer: PeerId
): Future[void] {.async: (raises: [CancelledError]).} =
  trace "Sending wantBlock request to", addresses, peer = blockPeer
  await self.network.request.sendWantList(
    blockPeer, addresses, wantType = WantType.WantBlock
  )

  archivist_block_exchange_want_block_lists_sent.inc()

proc sendWantBlock(
    self: BlockExcEngine, addresses: seq[BlockAddress], blockPeer: BlockExcPeerCtx
): Future[void] {.async: (raw: true, raises: [CancelledError]).} =
  if blockPeer.isNil:
    trace "Peer context is nil, skipping send"
    return

  self.sendWantBlock(addresses, blockPeer.id)

proc sendBatchedWantList(
    self: BlockExcEngine,
    peer: BlockExcPeerCtx,
    addresses: seq[BlockAddress],
    full: bool,
) {.async: (raises: [CancelledError]).} =
  var offset = 0
  while offset < addresses.len:
    let batchEnd = min(offset + DefaultMaxWantListBatchSize, addresses.len)
    let batch = addresses[offset ..< batchEnd]

    trace "Sending want list batch",
      peer = peer.id,
      batchSize = batch.len,
      offset = offset,
      total = addresses.len,
      full = full

    await self.network.request.sendWantList(
      peer.id, batch, full = full and offset == 0, sendDontHave = true
    )

    for address in batch:
      peer.lastSentWants.incl(address)

    offset = batchEnd

proc refreshBlockKnowledge(
    self: BlockExcEngine, peer: BlockExcPeerCtx, skipDelta = false, resetBackoff = false
) {.async: (raises: [CancelledError]).} =
  if peer.lastSentWants.len > 0:
    var toRemove: seq[BlockAddress]

    for address in peer.lastSentWants:
      if address notin self.pendingBlocks:
        toRemove.add(address)

        if toRemove.len >= CleanupBatchSize:
          await idleAsync()
          break

    for address in toRemove:
      peer.lastSentWants.excl(address)

  if self.pendingBlocks.wantListLen == 0:
    if peer.lastSentWants.len > 0:
      peer.lastSentWants.clear()
    return

  let peerHave = peer.peerHave
  var toAsk = initHashSet[BlockAddress]()
  for address in self.pendingBlocks.wantList:
    if address notin peerHave:
      toAsk.incl(address)

  if toAsk.len == 0:
    if peer.lastSentWants.len > 0:
      peer.lastSentWants.clear()
    return

  let newWants = toAsk - peer.lastSentWants
  if peer.lastSentWants.len > 0 and not skipDelta:
    if newWants.len > 0:
      await self.sendBatchedWantList(peer, newWants.toSeq, full = false)

      if resetBackoff:
        peer.wantsUpdated()
    else:
      trace "No changes in want list, skipping send", peer = peer.id

    peer.lastSentWants = toAsk
  else:
    peer.lastSentWants.clear()
    await self.sendBatchedWantList(peer, toAsk.toSeq, full = true)

    if resetBackoff:
      peer.wantsUpdated()

    peer.lastSentWants = toAsk

proc refreshBlockKnowledge(self: BlockExcEngine) {.async: (raises: [CancelledError]).} =
  let runtimeQuota = 10.milliseconds
  var lastIdle = Moment.now()

  for peer in self.peers.peers.values.toSeq:
    let
      hasNewBlocks = peer.lastRefresh < self.pendingBlocks.lastInclusion
      isKnowledgeStale = peer.isKnowledgeStale

    if isKnowledgeStale or hasNewBlocks:
      if not peer.refreshInProgress:
        peer.refreshRequested()
        await self.refreshBlockKnowledge(
          peer, skipDelta = isKnowledgeStale, resetBackoff = hasNewBlocks
        )

    if (Moment.now() - lastIdle) >= runtimeQuota:
      await idleAsync()

      lastIdle = Moment.now()

proc scheduleBlockSend(
  self: BlockExcEngine,
  address: BlockAddress,
  immediate = false,
  delay = DefaultBlockSendRetryDelay,
) {.gcsafe, raises: [].}

proc failBlockRequest(
  self: BlockExcEngine,
  address: BlockAddress,
  errType: typedesc[EngineError],
  msg: string,
) {.async: (raises: []).}

proc searchForNewPeers(self: BlockExcEngine, cid: Cid) =
  if self.lastDiscRequest + DiscoveryRateLimit < Moment.now():
    archivist_block_exchange_discovery_requests_total.inc()
    self.lastDiscRequest = Moment.now()
    self.discovery.queueFindBlocksReq(@[cid])

proc evictPeer(self: BlockExcEngine, peer: PeerId) {.gcsafe, async: (raises: []).} =
  trace "Evicting disconnected/departed peer", peer

  var
    pendingAddresses: seq[BlockAddress]
    requests: seq[Future[void]]

  let peerCtx = self.peers.get(peer)
  if not peerCtx.isNil:
    for address in peerCtx.blocksRequested:
      pendingAddresses.add(address)
      requests.add(self.pendingBlocks.clearRequest(address, peer))

    await noCancel allFutures(requests)

  self.peers.remove(peer)
  for address in pendingAddresses:
    if address in self.pendingBlocks:
      self.scheduleBlockSend(address)

proc randomPeer(peers: seq[BlockExcPeerCtx]): BlockExcPeerCtx =
  Rng.instance.sample(peers)

proc scheduleBlockSendTask(
    self: BlockExcEngine,
    address: BlockAddress,
    immediate: bool,
    delay = DefaultBlockSendRetryDelay,
) {.async: (raises: []).} =
  without handle =? self.pendingBlocks.getPendingHandle(address):
    self.pendingBlocks.clearScheduled(address)
    return

  if address notin self.pendingBlocks or self.pendingBlocks.isRequested(address):
    return

  if self.pendingBlocks.retriesExhausted(address):
    archivist_block_exchange_requests_failed_total.inc()
    self.pendingBlocks.failWantHandle(
      address, RetriesExhaustedEngineError, "Block request retries exhausted"
    )
    return

  if not immediate and not self.pendingBlocks.isFirstAttempt(address):
    let timer = sleepAsync(delay)
    try:
      await handle or timer
    except CatchableError as exc:
      trace "Exception in scheduling block send task", address, exc = exc.msg
    finally:
      if not timer.finished:
        await noCancel timer.cancelAndWait()

    if handle.finished:
      trace "Handle finished before queueing block", address
      return

  let enqueueFut = self.pendingBlocks.enqueue(address, 0)
  try:
    await handle or enqueueFut
  except CatchableError as exc:
    trace "Exception queuing block for send", address, exc = exc.msg
  finally:
    if handle.finished and not enqueueFut.finished:
      await noCancel enqueueFut.cancelAndWait()

proc scheduleBlockSend(
    self: BlockExcEngine,
    address: BlockAddress,
    immediate = false,
    delay = DefaultBlockSendRetryDelay,
) {.gcsafe, raises: [].} =
  self.trackedFutures.track(self.scheduleBlockSendTask(address, immediate, delay))

proc clearBlockRequestState(
    self: BlockExcEngine, address: BlockAddress
) {.async: (raises: []).} =
  if peerId =? self.pendingBlocks.getRequestPeer(address):
    let ctx = self.peers.get(peerId)
    if not ctx.isNil:
      ctx.blockRequestCancelled(address)
  await self.pendingBlocks.clearRequest(address)

proc failBlockRequest(
    self: BlockExcEngine,
    address: BlockAddress,
    errType: typedesc[EngineError],
    msg: string,
) {.async: (raises: []).} =
  await self.clearBlockRequestState(address)
  self.pendingBlocks.failWantHandle(address, errType, msg)

proc sendRequestBatch(
    self: BlockExcEngine, peerId: PeerId, addresses: seq[BlockAddress]
) {.async: (raises: [CancelledError]).} =
  if addresses.len == 0:
    trace "Cannot send empty batch", peerId
    return

  let peer = self.peers.get(peerId)
  if peer.isNil:
    trace "Unable to find peer to send batch to", peerId
    for address in addresses:
      self.pendingBlocks.clearScheduled(address)
      self.scheduleBlockSend(address)
    return

  var batch: seq[BlockAddress]
  for address in addresses:
    if address notin self.pendingBlocks or self.pendingBlocks.isRequested(address):
      continue

    if self.pendingBlocks.retriesExhausted(address):
      trace "Retries exhausted, skipping block", address
      archivist_block_exchange_requests_failed_total.inc()
      await self.failBlockRequest(
        address, RetriesExhaustedEngineError, "Block request retries exhausted"
      )
      continue

    let requested =
      self.pendingBlocks.markRequested(address, peerId, self.blockRequestTimeout)

    if requested != peerId.some:
      trace "Block already requested from another peer", address, peer = requested.get
      continue

    self.pendingBlocks.decRetries(address)
    peer.blockRequestScheduled(address)
    self.pendingBlocks.clearScheduled(address)
    batch.add(address)

  if batch.len == 0:
    trace "Batch is empty, skipping", peerId
    return

  if err =? catchAsync(await self.sendWantBlock(batch, peerId)).errorOption:
    warn "Failed to send wantBlock batch", peer = peerId, err = err.msg
    for address in batch:
      await self.pendingBlocks.clearRequest(address, peerId)
      peer.blockRequestCancelled(address)
      peer.cleanPresence(address)
      self.scheduleBlockSend(address)

proc sendRequestBatchTask(
    self: BlockExcEngine, peerId: PeerId, addresses: seq[BlockAddress]
) {.async: (raises: []).} =
  try:
    await self.sendRequestBatch(peerId, addresses)
  except CatchableError as exc:
    trace "Exception sending batch", peerId

type
  BatchTimer = Future[void]
  BatchReq = object
    batch: seq[BlockAddress]
    timer: BatchTimer

func hash(timer: BatchTimer): Hash =
  cast[pointer](timer).hash

proc blockRequestScheduler(self: BlockExcEngine) {.async: (raises: []).} =
  var
    byPeer: Table[PeerId, BatchReq]
    timers: Table[Future[void], PeerId]

  try:
    while self.blockexcRunning:
      var finished: FutureBase
      let next = self.pendingBlocks.dequeue()
      try:
        finished = await FutureBase(next).race(timers.keys.toSeq.mapIt(FutureBase(it)))
      finally:
        if not next.finished:
          await noCancel next.cancelAndWait()

      if not next.completed:
        let batchTimer = BatchTimer(finished)
        if peerId =? timers .? [batchTimer]:
          timers.del(batchTimer)
          if batchReq =? byPeer .? [peerId]:
            byPeer.del(peerId)
            if batchReq.batch.len > 0:
              self.trackedFutures.track(
                self.sendRequestBatchTask(peerId, batchReq.batch)
              )
              trace "Request batch task dispatched after timeout deadline",
                peerId, batch = batchReq.batch.len
          else:
            warn "No peer found for timer", peerId
        continue

      let address = await next
      trace "Got block from request queue", address

      if address notin self.pendingBlocks or self.pendingBlocks.isRequested(address):
        trace "Address is not pending or already requested", address
        self.pendingBlocks.clearScheduled(address)
        continue

      if self.pendingBlocks.retriesExhausted(address):
        trace "Retries exhausted, skipping block", address
        archivist_block_exchange_requests_failed_total.inc()
        await self.failBlockRequest(
          address, RetriesExhaustedEngineError, "Block request retries exhausted"
        )
        continue

      let peers = self.peers.getPeersForBlock(address)
      if peers.with.len == 0 and peers.without.len > 0:
        await self.refreshBlockKnowledge()

      if peers.with.len == 0:
        self.searchForNewPeers(address.cidOrTreeCid)
        self.pendingBlocks.enterDiscoveryWait(address, self.discoveryDeadline)
        trace "No peer for block, entering discovery wait", address
        continue

      let peer = self.selectPeer(peers.with)
      if peer.isNil:
        trace "No peer context, entering discovery wait", address
        self.pendingBlocks.enterDiscoveryWait(address, self.discoveryDeadline)
        continue

      var peerBatch: seq[BlockAddress]
      byPeer.withValue(peer.id, req):
        req[].batch.add(address)
        peerBatch = req[].batch
      do:
        let timer = sleepAsync(self.wantBlockBatchTimeout)
        byPeer[peer.id] = BatchReq(batch: @[address], timer: timer)
        timers[timer] = peer.id
        continue

      if peerBatch.len >= self.wantBlockBatchSize:
        if batchReq =? byPeer .? [peer.id]:
          let batchTimer = BatchTimer(batchReq.timer)
          await noCancel batchTimer.cancelAndWait()
          timers.del(batchTimer)
          byPeer.del(peer.id)
          self.trackedFutures.track(self.sendRequestBatchTask(peer.id, peerBatch))
  except CancelledError:
    byPeer.clear()
    timers.clear()
    warn "Request scheduling cancelled!"

  for timer in timers.keys.toSeq:
    if not timer.finished:
      await noCancel timer.cancelAndWait()

  trace "Block request scheduling stopped"

proc requestDeliveries*(
    self: BlockExcEngine, addresses: seq[BlockAddress], priority = 0
): ?!seq[BlockHandle] =
  var handles: seq[BlockHandle]

  for address in addresses.deduplicate():
    let handle = self.pendingBlocks.getWantHandle(address)
    self.scheduleBlockSend(address)
    handles.add(handle)

  success handles

proc requestDelivery*(
    self: BlockExcEngine, address: BlockAddress, priority = 0
): ?!BlockHandle =
  let handle = self.pendingBlocks.getWantHandle(address)
  self.scheduleBlockSend(address)
  success handle

proc completeBlocks*(
    self: BlockExcEngine, blocksDelivery: seq[BlockDelivery]
) {.async: (raises: [CancelledError]).} =
  await self.resolveBlocks(blocksDelivery)

proc completeBlock*(
    self: BlockExcEngine, address: BlockAddress, blk: Block
) {.async: (raises: [CancelledError]).} =
  await self.completeBlocks(@[BlockDelivery(address: address, blk: blk)])

proc blockPresenceHandler*(
    self: BlockExcEngine, peer: PeerId, blocks: seq[BlockPresence]
) {.async: (raises: []).} =
  trace "Received block presence from peer", peer, len = blocks.len
  let peerCtx = self.peers.get(peer)
  var ourWantList: HashSet[BlockAddress]
  for address in self.pendingBlocks.wantList:
    ourWantList.incl(address)

  if peerCtx.isNil:
    return

  peerCtx.refreshReplied()

  for blk in blocks:
    if presence =? Presence.init(blk):
      peerCtx.setPresence(presence)

  let
    peerHave = peerCtx.peerHave
    dontWantCids = peerHave - ourWantList

  if dontWantCids.len > 0:
    peerCtx.cleanPresence(dontWantCids.toSeq)

  for address in ourWantList:
    if address in peerHave and not self.pendingBlocks.retriesExhausted(address) and
        not self.pendingBlocks.isRequested(address):
      self.pendingBlocks.wakeOnPresence(address)

proc scheduleTasks(
    self: BlockExcEngine, blocksDelivery: seq[BlockDelivery]
) {.async: (raises: [CancelledError]).} =
  for peerCtx in self.peers:
    for blockDelivery in blocksDelivery:
      if blockDelivery.address in peerCtx.wantedBlocks:
        self.scheduleTask(peerCtx)
        break

proc cancelBlocks(
    self: BlockExcEngine, addrs: seq[BlockAddress]
) {.async: (raises: [CancelledError]).} =
  let blocksDelivered = toHashSet(addrs)
  var scheduledCancellations: Table[PeerId, HashSet[BlockAddress]]

  if self.peers.len == 0:
    return

  proc dispatchCancellations(
      peerId: PeerId, addresses: HashSet[BlockAddress]
  ): Future[PeerId] {.async: (raises: [CancelledError]).} =
    await self.network.request.sendWantCancellations(peerId, addresses.toSeq)
    peerId

  try:
    for peerCtx in self.peers.peers.values:
      let intersection = peerCtx.blocksRequested.intersection(blocksDelivered)
      if intersection.len > 0:
        scheduledCancellations[peerCtx.id] = intersection
        peerCtx.cleanPresence(addrs)
        for address in intersection:
          peerCtx.blockRequestCancelled(address)

    if scheduledCancellations.len == 0:
      return

    var futures: seq[Future[PeerId]]
    for peerId, addresses in scheduledCancellations:
      futures.add(dispatchCancellations(peerId, addresses))

    let (_, failedFuts) = await allFinishedFailed[PeerId](futures)
    if failedFuts.len > 0:
      warn "Failed to send block request cancellations to peers", peers = failedFuts.len
  except CancelledError as exc:
    warn "Error sending block request cancellations", error = exc.msg
    raise exc
  except CatchableError as exc:
    warn "Error sending block request cancellations", error = exc.msg

proc releaseHandle*(
    self: BlockExcEngine, handle: BlockHandle
): Future[void] {.async: (raises: [CancelledError]).} =
  let requested = self.pendingBlocks.getRequestPeer(handle)

  if address =? self.pendingBlocks.getHandleAddress(handle):
    await noCancel handle.cancelAndWait()

    await self.cancelBlocks(@[address])
    if peerId =? requested:
      let ctx = self.peers.get(peerId)
      if not ctx.isNil:
        ctx.blockRequestCancelled(address)

proc resolveBlocks*(
    self: BlockExcEngine, blocksDelivery: seq[BlockDelivery]
) {.async: (raises: [CancelledError]).} =
  self.pendingBlocks.resolve(blocksDelivery)
  await self.scheduleTasks(blocksDelivery)
  await self.cancelBlocks(blocksDelivery.mapIt(it.address))

proc resolveBlocks*(
    self: BlockExcEngine, blocks: seq[Block]
) {.async: (raises: [CancelledError]).} =
  await self.resolveBlocks(
    blocks.mapIt(
      BlockDelivery(blk: it, address: BlockAddress(leaf: false, cid: it.cid))
    )
  )

proc validateBlockDelivery(self: BlockExcEngine, bd: BlockDelivery): ?!void =
  if bd.address notin self.pendingBlocks:
    return failure("Received block is not currently a pending block")

  if bd.address.leaf:
    without proof =? bd.proof:
      return failure("Missing proof")

    if proof.index != bd.address.index:
      return failure(
        "Proof index " & $proof.index & " doesn't match leaf index " & $bd.address.index
      )

    without leaf =? bd.blk.cid.mhash.mapFailure, err:
      return failure("Unable to get mhash from cid for block, nested err: " & err.msg)

    without treeRoot =? bd.address.treeCid.mhash.mapFailure, err:
      return
        failure("Unable to get mhash from treeCid for block, nested err: " & err.msg)

    if err =? proof.verify(leaf, treeRoot).errorOption:
      return failure("Unable to verify proof for block, nested err: " & err.msg)
  else:
    if bd.address.cid != bd.blk.cid:
      return failure(
        "Delivery cid " & $bd.address.cid & " doesn't match block cid " & $bd.blk.cid
      )

  success()

proc blocksDeliveryHandler*(
    self: BlockExcEngine,
    peer: PeerId,
    blocksDelivery: seq[BlockDelivery],
    allowSpurious = false,
) {.async: (raises: [CancelledError]).} =
  trace "Received blocks from peer", peer, count = blocksDelivery.len

  var
    validatedBlocksDelivery: seq[BlockDelivery]
    leafByTree: Table[Cid, seq[(Block, Natural, ArchivistProof)]]
    nonLeafDeliveries: seq[BlockDelivery]
    acceptedAddresses: seq[BlockAddress]

  let
    peerCtx = self.peers.get(peer)
    runtimeQuota = 10.milliseconds

  var lastIdle = Moment.now()
  for bd in blocksDelivery:
    logScope:
      peer = peer
      address = bd.address

    try:
      if not allowSpurious and
          (peerCtx == nil or not peerCtx.isBlockRequested(bd.address)):
        warn "Dropping unrequested or duplicate block received from peer"
        archivist_block_exchange_spurious_blocks_received.inc()
        continue

      if err =? self.validateBlockDelivery(bd).errorOption:
        warn "Block validation failed", msg = err.msg
        if not peerCtx.isNil:
          peerCtx.blockRequestCancelled(bd.address)
          peerCtx.cleanPresence(bd.address)
        await self.pendingBlocks.clearRequest(bd.address, peer)
        self.scheduleBlockSend(bd.address)
        continue

      if bd.address.leaf:
        without proof =? bd.proof:
          warn "Proof expected for a leaf block delivery"
          continue

        leafByTree.withValue(bd.address.treeCid, slot):
          slot[].add((bd.blk, bd.address.index, proof))
        do:
          leafByTree[bd.address.treeCid] = @[(bd.blk, bd.address.index, proof)]
      else:
        nonLeafDeliveries.add(bd)
    except CancelledError as exc:
      trace "blocksDeliveryHandler cancelled"
      raise exc
    except CatchableError as exc:
      warn "Error handling block delivery", error = exc.msg
      continue

    validatedBlocksDelivery.add(bd)

    if (Moment.now() - lastIdle) >= runtimeQuota:
      await idleAsync()
      lastIdle = Moment.now()

  for treeCid, items in leafByTree:
    let putResult = await self.localStore.putBlocks(treeCid, items)
    if err =? putResult.errorOption:
      error "Unable to store leaf blocks", treeCid, err = err.msg
      for delivery in validatedBlocksDelivery:
        if delivery.address.leaf and delivery.address.treeCid == treeCid:
          await self.failBlockRequest(
            delivery.address, StorageFailedEngineError, err.msg
          )
      validatedBlocksDelivery.keepItIf(
        not (it.address.leaf and it.address.treeCid == treeCid)
      )
      continue

    for delivery in validatedBlocksDelivery:
      if delivery.address.leaf and delivery.address.treeCid == treeCid:
        acceptedAddresses.add(delivery.address)

  for bd in nonLeafDeliveries:
    without manifest =? Manifest.decode(bd.blk), err:
      error "Unable to decode manifest block", err = err.msg
      if not peerCtx.isNil:
        peerCtx.blockRequestCancelled(bd.address)
        peerCtx.cleanPresence(bd.address)
      await self.pendingBlocks.clearRequest(bd.address, peer)
      self.scheduleBlockSend(bd.address)
      validatedBlocksDelivery.keepItIf(it.address.cid != bd.address.cid)
      continue

    let storeResult = await self.localStore.storeManifest(manifest)
    if err =? storeResult.errorOption:
      error "Unable to store manifest", err = err.msg
      await self.failBlockRequest(bd.address, StorageFailedEngineError, err.msg)
      validatedBlocksDelivery.keepItIf(it.address.cid != bd.address.cid)
      continue

    acceptedAddresses.add(bd.address)

  if not peerCtx.isNil:
    for address in acceptedAddresses:
      peerCtx.blockRequestAccepted(address)
      await self.pendingBlocks.clearRequest(address, peer)

  archivist_block_exchange_blocks_received.inc(validatedBlocksDelivery.len.int64)

  await self.resolveBlocks(validatedBlocksDelivery)

proc wantListHandler*(
    self: BlockExcEngine, peer: PeerId, wantList: WantList
) {.async: (raises: []).} =
  trace "Received want list from peer", peer, wantList = wantList.entries.len

  let peerCtx = self.peers.get(peer)
  if peerCtx.isNil:
    return

  var
    presence: seq[BlockPresence]
    schedulePeer = false

  let runtimeQuota = 10.milliseconds
  var lastIdle = Moment.now()

  try:
    for e in wantList.entries:
      logScope:
        peer = peerCtx.id
        address = e.address
        wantType = $e.wantType

      if e.cancel:
        peerCtx.wantedBlocks.excl(e.address)
        peerCtx.markBlockAsNotSent(e.address)
        continue

      case e.wantType
      of WantType.WantHave:
        let have =
          try:
            if e.address.leaf:
              (await self.localStore.hasBlock(e.address.treeCid, e.address.index)) |?
                false
            else:
              (await self.localStore.hasBlock(e.address.cid)) |? false
          except CatchableError:
            false

        if have:
          presence.add(
            BlockPresence(address: e.address, `type`: BlockPresenceType.Have)
          )
        elif e.sendDontHave:
          presence.add(
            BlockPresence(address: e.address, `type`: BlockPresenceType.DontHave)
          )

        archivist_block_exchange_want_have_lists_received.inc()
      of WantType.WantBlock:
        peerCtx.wantedBlocks.incl(e.address)
        schedulePeer = true
        archivist_block_exchange_want_block_lists_received.inc()

      if presence.len >= PresenceBatchSize or (Moment.now() - lastIdle) >= runtimeQuota:
        if presence.len > 0:
          await self.network.request.sendPresence(peer, presence)
          presence = @[]

        await idleAsync()
        lastIdle = Moment.now()

    if presence.len > 0:
      await self.network.request.sendPresence(peer, presence)

    if schedulePeer:
      self.scheduleTask(peerCtx)
  except CancelledError as exc:
    trace "want list handler cancelled", peer, error = exc.msg

proc setupPeer*(
    self: BlockExcEngine, peer: PeerId
) {.async: (raises: [CancelledError]).} =
  trace "Setting up peer", peer

  if peer notin self.peers:
    self.peers.add(BlockExcPeerCtx.new(peer))

  let peerCtx = self.peers.get(peer)
  await self.refreshBlockKnowledge(peerCtx, skipDelta = true)

proc taskHandler*(
    self: BlockExcEngine, peerCtx: BlockExcPeerCtx
) {.gcsafe, async: (raises: [CancelledError]).} =
  let wantedBlocks = peerCtx.wantedBlocks.toSeq.filterIt(not peerCtx.isBlockSent(it))
  if wantedBlocks.len == 0:
    return

  for address in wantedBlocks:
    peerCtx.markBlockAsSent(address)

  var
    leafIndicesByTree: Table[Cid, seq[Natural]]
    nonLeafAddresses: seq[BlockAddress]
    blockDeliveries: seq[BlockDelivery]
    deliveredAddresses = initHashSet[BlockAddress]()

  try:
    for wantedBlock in wantedBlocks:
      if wantedBlock.leaf:
        leafIndicesByTree.withValue(wantedBlock.treeCid, slot):
          slot[].add(wantedBlock.index)
        do:
          leafIndicesByTree[wantedBlock.treeCid] = @[wantedBlock.index]
      else:
        nonLeafAddresses.add(wantedBlock)

    if nonLeafAddresses.len > 0:
      let cids = nonLeafAddresses.mapIt(it.cid)
      without blocks =? await self.localStore.getBlocks(cids), err:
        error "Error getting non-leaf blocks from local store", err = err.msg
        return

      var blocksByCid: Table[Cid, Block]
      for blk in blocks:
        blocksByCid[blk.cid] = blk

      for address in nonLeafAddresses:
        if blk =? blocksByCid .? [address.cid]:
          blockDeliveries.add(BlockDelivery(address: address, blk: blk))

    for treeCid, indices in leafIndicesByTree:
      without items =? await self.localStore.getBlocksAndProofs(treeCid, indices), err:
        error "Error getting leaf blocks from local store", treeCid, err = err.msg
        continue

      var itemsByIndex: Table[Natural, (Block, ArchivistProof)]
      for item in items:
        itemsByIndex[item[0]] = (item[1], item[2])

      for index in indices:
        if entry =? itemsByIndex .? [index]:
          let (blk, proof) = entry
          if proof.isNil:
            warn "Skipping leaf delivery without proof", treeCid, index
            continue

          blockDeliveries.add(
            BlockDelivery(
              address: BlockAddress.init(treeCid, index), blk: blk, proof: proof.some
            )
          )

    if blockDeliveries.len == 0:
      return

    for batch in blockDeliveries.batches(self.maxBlocksPerMessage):
      await self.network.request.sendBlocksDelivery(peerCtx.id, batch)
      archivist_block_exchange_blocks_sent.inc(batch.len.int64)
      for delivery in batch:
        deliveredAddresses.incl(delivery.address)

    for address in deliveredAddresses:
      peerCtx.wantedBlocks.excl(address)
  finally:
    let wantedSet = wantedBlocks.toHashSet
    var remainingSent = initHashSet[BlockAddress]()
    for address in peerCtx.blocksSent:
      if address notin wantedSet or address in deliveredAddresses:
        remainingSent.incl(address)
    peerCtx.blocksSent = remainingSent

proc blockexcTaskRunner(self: BlockExcEngine) {.async: (raises: []).} =
  try:
    while self.blockexcRunning:
      let peerCtx = await self.taskQueue.pop()
      await self.taskHandler(peerCtx)
  except CancelledError:
    trace "block exchange task runner cancelled"
  except CatchableError as exc:
    error "error running block exchange task", error = exc.msg

proc new*(
    T: type BlockExcEngine,
    localStore: BlockStore,
    network: BlockExcNetwork,
    discovery: DiscoveryEngine,
    advertiser: Advertiser,
    peerStore: PeerCtxStore,
    pendingBlocks: PendingBlocksManager,
    maxBlocksPerMessage = DefaultMaxBlocksPerMessage,
    concurrentTasks = DefaultConcurrentTasks,
    selectPeer: PeerSelector = randomPeer,
    wantBlockBatchSize = DefaultWantBlockBatchSize,
    wantBlockBatchTimeout = DefaultWantBlockBatchTimeout,
    blockRequestTimeout = DefaultRequestTimeout,
): BlockExcEngine =
  let self = BlockExcEngine(
    localStore: localStore,
    peers: peerStore,
    pendingBlocks: pendingBlocks,
    network: network,
    concurrentTasks: concurrentTasks,
    trackedFutures: TrackedFutures(),
    maxBlocksPerMessage: maxBlocksPerMessage,
    wantBlockBatchSize: wantBlockBatchSize,
    wantBlockBatchTimeout: wantBlockBatchTimeout,
    blockRequestTimeout: blockRequestTimeout,
    taskQueue: newAsyncHeapQueue[BlockExcPeerCtx](DefaultTaskQueueSize),
    discovery: discovery,
    advertiser: advertiser,
    selectPeer: selectPeer,
  )

  proc peerEventHandler(
      peerId: PeerId, event: PeerEvent
  ): Future[void] {.gcsafe, async: (raises: [CancelledError]).} =
    if event.kind == PeerEventKind.Joined:
      await self.setupPeer(peerId)
    else:
      await self.evictPeer(peerId)

  proc pendingAbandonHandler(address: BlockAddress) {.gcsafe, async: (raises: []).} =
    trace "Running abandon block hook", address
    await self.clearBlockRequestState(address)

  proc pendingTimeoutHandler(
      address: BlockAddress, peer: PeerId
  ) {.gcsafe, async: (raises: []).} =
    trace "Block request timed out", address, peer
    archivist_block_exchange_peer_timeouts_total.inc()
    self.network.dropPeer(peer)
    await self.evictPeer(peer)

  pendingBlocks.onAbandon = pendingAbandonHandler
  pendingBlocks.onTimeout = pendingTimeoutHandler

  if not isNil(network.switch):
    network.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Joined)
    network.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Left)

  proc blockWantListHandler(
      peer: PeerId, wantList: WantList
  ): Future[void] {.async: (raw: true, raises: []).} =
    self.wantListHandler(peer, wantList)

  proc blockPresenceHandler(
      peer: PeerId, presence: seq[BlockPresence]
  ): Future[void] {.async: (raw: true, raises: []).} =
    self.blockPresenceHandler(peer, presence)

  proc blocksDeliveryHandler(
      peer: PeerId, blocksDelivery: seq[BlockDelivery]
  ): Future[void] {.async: (raises: []).} =
    try:
      await self.blocksDeliveryHandler(peer, blocksDelivery)
    except CancelledError:
      trace "blocks delivery handler cancelled", peer

  network.handlers = BlockExcHandlers(
    onWantList: blockWantListHandler,
    onBlocksDelivery: blocksDeliveryHandler,
    onPresence: blockPresenceHandler,
  )

  self
