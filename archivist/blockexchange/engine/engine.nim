## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/options
import std/sequtils
import std/sets
import std/tables

import pkg/chronos
import pkg/libp2p/[cid, switch, multihash, multicodec]
import pkg/metrics
import pkg/questionable

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
import ./pendingblocks

export peers, pendingblocks, discovery

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
  DefaultTaskQueueSize = 100
  DefaultConcurrentTasks = 10
  DefaultMaxBlocksPerMessage = 20
  DiscoveryRateLimit = 3.seconds
  DefaultPeerActivityTimeout = 1.minutes
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

proc start*(self: BlockExcEngine) {.async: (raises: []).} =
  await self.discovery.start()
  await self.advertiser.start()

  trace "Blockexc starting with concurrent tasks", tasks = self.concurrentTasks
  if self.blockexcRunning:
    warn "Starting blockexc twice"
    return

  self.blockexcRunning = true
  for i in 0 ..< self.concurrentTasks:
    let fut = self.blockexcTaskRunner()
    self.trackedFutures.track(fut)

proc stop*(self: BlockExcEngine) {.async: (raises: []).} =
  await self.trackedFutures.cancelTracked()
  await self.network.stop()
  await self.discovery.stop()
  await self.advertiser.stop()

  if not self.blockexcRunning:
    warn "Stopping blockexc without starting it"
    return

  self.blockexcRunning = false

proc sendWantBlock(
    self: BlockExcEngine, addresses: seq[BlockAddress], blockPeer: BlockExcPeerCtx
): Future[void] {.async: (raises: [CancelledError]).} =
  trace "Sending wantBlock request to", addresses, peer = blockPeer.id
  await self.network.request.sendWantList(
    blockPeer.id, addresses, wantType = WantType.WantBlock
  )

  archivist_block_exchange_want_block_lists_sent.inc()

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

proc searchForNewPeers(self: BlockExcEngine, cid: Cid) =
  if self.lastDiscRequest + DiscoveryRateLimit < Moment.now():
    archivist_block_exchange_discovery_requests_total.inc()
    self.lastDiscRequest = Moment.now()
    self.discovery.queueFindBlocksReq(@[cid])

proc evictPeer(self: BlockExcEngine, peer: PeerId) =
  trace "Evicting disconnected/departed peer", peer

  let peerCtx = self.peers.get(peer)
  if not peerCtx.isNil:
    for address in peerCtx.blocksRequested:
      self.pendingBlocks.clearRequest(address, peer.some)

  self.peers.remove(peer)

proc randomPeer(peers: seq[BlockExcPeerCtx]): BlockExcPeerCtx =
  Rng.instance.sample(peers)

proc downloadInternal(
    self: BlockExcEngine, address: BlockAddress
) {.async: (raises: []).} =
  logScope:
    address = address

  let handle = self.pendingBlocks.getWantHandle(address)
  try:
    while address in self.pendingBlocks:
      if self.pendingBlocks.retriesExhausted(address):
        archivist_block_exchange_requests_failed_total.inc()
        handle.fail(newException(RetriesExhaustedError, "Error retries exhausted"))
        break

      let peers = self.peers.getPeersForBlock(address)
      logScope:
        peersWith = peers.with.len
        peersWithout = peers.without.len

      if peers.with.len == 0:
        if peers.without.len > 0:
          await self.refreshBlockKnowledge()

        self.searchForNewPeers(address.cidOrTreeCid)

        let nextDiscovery =
          if self.lastDiscRequest + DiscoveryRateLimit > Moment.now():
            self.lastDiscRequest + DiscoveryRateLimit - Moment.now()
          else:
            0.milliseconds

        let retryDelay = max(self.pendingBlocks.retryInterval, nextDiscovery)
        await handle or sleepAsync(retryDelay)
        if handle.finished:
          break

        self.pendingBlocks.decRetries(address)
        continue

      let scheduledPeer =
        if not self.pendingBlocks.isRequested(address):
          let peer = self.selectPeer(peers.with)
          if self.pendingBlocks.markRequested(address, peer.id):
            peer.blockRequestScheduled(address)
            await self.sendWantBlock(@[address], peer)
            peer
          else:
            let peerId = self.pendingBlocks.getRequestPeer(address)
            if peerId.isSome:
              self.peers.get(peerId.get())
            else:
              nil
        else:
          let peerId = self.pendingBlocks.getRequestPeer(address)
          if peerId.isSome:
            self.peers.get(peerId.get())
          else:
            nil

      if scheduledPeer.isNil:
        self.pendingBlocks.clearRequest(address)
        continue

      let activityTimer = scheduledPeer.activityTimer()
      await handle or activityTimer
      activityTimer.cancelSoon()

      self.pendingBlocks.decRetries(address)
      if handle.finished:
        break

      archivist_block_exchange_peer_timeouts_total.inc()
      self.network.dropPeer(scheduledPeer.id)
      self.evictPeer(scheduledPeer.id)
  except CancelledError:
    if not handle.finished:
      await handle.cancelAndWait()
  except RetriesExhaustedError as exc:
    warn "Retries exhausted for block", address, exc = exc.msg
    archivist_block_exchange_requests_failed_total.inc()
    if not handle.finished:
      handle.fail(exc)
  finally:
    self.pendingBlocks.clearRequest(address)

proc requestBlock*(
    self: BlockExcEngine, address: BlockAddress
): Future[?!Block] {.async: (raises: [CancelledError]).} =
  if address notin self.pendingBlocks:
    self.trackedFutures.track(self.downloadInternal(address))

  try:
    let handle = self.pendingBlocks.getWantHandle(address)
    success await handle
  except CancelledError as err:
    warn "Block request cancelled", address
    raise err
  except CatchableError as err:
    error "Block request failed", address, err = err.msg
    failure err

proc requestBlock*(
    self: BlockExcEngine, cid: Cid
): Future[?!Block] {.async: (raw: true, raises: [CancelledError]).} =
  self.requestBlock(BlockAddress.init(cid))

proc completeBlock*(self: BlockExcEngine, address: BlockAddress, blk: Block) =
  if address in self.pendingBlocks.blocks:
    self.pendingBlocks.completeWantHandle(address, blk)
  else:
    warn "Attempted to complete non-pending block", address

proc blockPresenceHandler*(
    self: BlockExcEngine, peer: PeerId, blocks: seq[BlockPresence]
) {.async: (raises: []).} =
  trace "Received block presence from peer", peer, len = blocks.len
  let
    peerCtx = self.peers.get(peer)
    ourWantList = toHashSet(self.pendingBlocks.wantList.toSeq)

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

  let ourWantCids = ourWantList.filterIt(
    it in peerHave and not self.pendingBlocks.retriesExhausted(it) and
      self.pendingBlocks.markRequested(it, peer)
  ).toSeq

  for address in ourWantCids:
    self.pendingBlocks.decRetries(address)
    peerCtx.blockRequestScheduled(address)

  if ourWantCids.len > 0:
    try:
      await self.sendWantBlock(ourWantCids, peerCtx)
    except CancelledError as err:
      warn "Failed to send wantBlock to peer", peer, err = err.msg
      for address in ourWantCids:
        self.pendingBlocks.clearRequest(address, peer.some)
        peerCtx.blockRequestCancelled(address)
    except CatchableError as err:
      warn "Failed to send wantBlock to peer", peer, err = err.msg
      for address in ourWantCids:
        self.pendingBlocks.clearRequest(address, peer.some)
        peerCtx.blockRequestCancelled(address)

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
      entry: tuple[peerId: PeerId, addresses: HashSet[BlockAddress]]
  ): Future[PeerId] {.async: (raises: [CancelledError]).} =
    await self.network.request.sendWantCancellations(
      entry.peerId, entry.addresses.toSeq
    )
    entry.peerId

  try:
    for peerCtx in self.peers.peers.values:
      let intersection = peerCtx.blocksRequested.intersection(blocksDelivered)
      if intersection.len > 0:
        scheduledCancellations[peerCtx.id] = intersection

    if scheduledCancellations.len == 0:
      return

    let (succeededFuts, failedFuts) = await allFinishedFailed[PeerId](
      toSeq(scheduledCancellations.pairs).map(dispatchCancellations)
    )

    (await allFinished(succeededFuts)).mapIt(it.read).apply do(peerId: PeerId):
      let ctx = self.peers.get(peerId)
      if not ctx.isNil:
        ctx.cleanPresence(addrs)
        for address in scheduledCancellations[peerId]:
          ctx.blockRequestCancelled(address)

    if failedFuts.len > 0:
      warn "Failed to send block request cancellations to peers", peers = failedFuts.len
  except CancelledError as exc:
    warn "Error sending block request cancellations", error = exc.msg
    raise exc
  except CatchableError as exc:
    warn "Error sending block request cancellations", error = exc.msg

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
  trace "Received blocks from peer", peer, blocks = blocksDelivery.mapIt(it.address)

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
    except CatchableError as exc:
      warn "Error handling block delivery", error = exc.msg
      continue

    validatedBlocksDelivery.add(bd)

    if (Moment.now() - lastIdle) >= runtimeQuota:
      await idleAsync()
      lastIdle = Moment.now()

  for treeCid, items in leafByTree:
    if err =?
        catchAsync(await self.localStore.putBlocks(treeCid, items)).flatten.errorOption:
      error "Unable to store leaf blocks", treeCid, err = err.msg
      validatedBlocksDelivery.keepItIf(
        not (it.address.leaf and it.address.treeCid == treeCid)
      )
    else:
      for delivery in validatedBlocksDelivery:
        if delivery.address.leaf and delivery.address.treeCid == treeCid:
          acceptedAddresses.add(delivery.address)

  for bd in nonLeafDeliveries:
    without manifest =? Manifest.decode(bd.blk), err:
      error "Unable to decode manifest block", err = err.msg
      validatedBlocksDelivery.keepItIf(it.address.cid != bd.address.cid)
      continue

    if err =?
        catchAsync(await self.localStore.storeManifest(manifest)).flatten.errorOption:
      error "Unable to store manifest", err = err.msg
      validatedBlocksDelivery.keepItIf(it.address.cid != bd.address.cid)
    else:
      acceptedAddresses.add(bd.address)

  if not peerCtx.isNil:
    for address in acceptedAddresses:
      peerCtx.blockRequestAccepted(address)

  archivist_block_exchange_blocks_received.inc(validatedBlocksDelivery.len.int64)

  if err =? catchAsync(await self.resolveBlocks(validatedBlocksDelivery)).errorOption:
    warn "Error resolving blocks", err = err.msg

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

        try:
          await idleAsync()
        except CancelledError:
          discard

        lastIdle = Moment.now()

    if presence.len > 0:
      await self.network.request.sendPresence(peer, presence)

    if schedulePeer:
      self.scheduleTask(peerCtx)
  except CancelledError as exc:
    warn "Error processing want list", error = exc.msg

proc setupPeer*(
    self: BlockExcEngine, peer: PeerId
) {.async: (raises: [CancelledError]).} =
  trace "Setting up peer", peer

  if peer notin self.peers:
    self.peers.add(
      BlockExcPeerCtx(id: peer, activityTimeout: DefaultPeerActivityTimeout)
    )

  let peerCtx = self.peers.get(peer)
  await self.refreshBlockKnowledge(peerCtx, skipDelta = true)

proc splitBatches[T](values: seq[T], batchSize: int): seq[seq[T]] =
  var offset = 0
  while offset < values.len:
    let batchEnd = min(offset + batchSize, values.len)
    result.add(values[offset ..< batchEnd])
    offset = batchEnd

proc taskHandler*(
    self: BlockExcEngine, peerCtx: BlockExcPeerCtx
) {.gcsafe, async: (raises: [CancelledError, RetriesExhaustedError]).} =
  let wantedBlocks = peerCtx.wantedBlocks.toSeq.filterIt(not peerCtx.isBlockSent(it))
  if wantedBlocks.len == 0:
    return

  for wantedBlock in wantedBlocks:
    peerCtx.markBlockAsSent(wantedBlock)

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
        if blk =? blocksByCid.?[address.cid]:
          blockDeliveries.add(BlockDelivery(address: address, blk: blk))

    for treeCid, indices in leafIndicesByTree:
      without items =? await self.localStore.getBlocksAndProofs(treeCid, indices), err:
        error "Error getting leaf blocks from local store", treeCid, err = err.msg
        continue

      var itemsByIndex: Table[Natural, (Block, ArchivistProof)]
      for item in items:
        itemsByIndex[item[0]] = (item[1], item[2])

      for index in indices:
        if entry =? itemsByIndex.?[index]:
          let (blk, proof) = entry
          blockDeliveries.add(
            BlockDelivery(
              address: BlockAddress.init(treeCid, index), blk: blk, proof: proof.some
            )
          )

    if blockDeliveries.len == 0:
      return

    for batch in splitBatches(blockDeliveries, self.maxBlocksPerMessage):
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
      if address notin wantedSet:
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
): BlockExcEngine =
  let self = BlockExcEngine(
    localStore: localStore,
    peers: peerStore,
    pendingBlocks: pendingBlocks,
    network: network,
    concurrentTasks: concurrentTasks,
    trackedFutures: TrackedFutures(),
    maxBlocksPerMessage: maxBlocksPerMessage,
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
      self.evictPeer(peerId)

  if not isNil(network.switch):
    network.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Joined)
    network.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Left)

  proc blockWantListHandler(
      peer: PeerId, wantList: WantList
  ): Future[void] {.async: (raises: []).} =
    self.wantListHandler(peer, wantList)

  proc blockPresenceHandler(
      peer: PeerId, presence: seq[BlockPresence]
  ): Future[void] {.async: (raises: []).} =
    self.blockPresenceHandler(peer, presence)

  proc blocksDeliveryHandler(
      peer: PeerId, blocksDelivery: seq[BlockDelivery]
  ): Future[void] {.async: (raises: []).} =
    try:
      await self.blocksDeliveryHandler(peer, blocksDelivery)
    except CancelledError:
      discard

  network.handlers = BlockExcHandlers(
    onWantList: blockWantListHandler,
    onBlocksDelivery: blocksDeliveryHandler,
    onPresence: blockPresenceHandler,
  )

  self
