## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/hashes
import std/options
import std/sequtils
import std/sets
import std/tables
import std/strformat
import std/algorithm

import pkg/chronos
import pkg/libp2p/[cid, switch, multihash, multicodec]
import ./metrics
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
import ./peerscoring

export peers, pendingblocks, discovery, errors, peerscoring

logScope:
  topics = "archivist blockexcengine"

const
  DefaultTaskQueueSize = 128
  DefaultConcurrentTasks = 30
  DefaultWantBlockBatchSize = DefaultMaxBatchBlocks
  DefaultWantBlockBatchTimeout = 5.millis
  DiscoveryRateLimit = 3.seconds
  PresenceBatchSize = DefaultMaxWantListBatchSize
  CleanupBatchSize = 2048
  DefaultWantHaveTopK* = 3

type
  TaskHandler* = proc(task: BlockExcPeerCtx): Future[void] {.gcsafe.}
  TaskScheduler* = proc(task: BlockExcPeerCtx): bool {.gcsafe.}
  PeerSelector* = proc(
    peers: seq[BlockExcPeerCtx], address: BlockAddress
  ): BlockExcPeerCtx {.gcsafe, raises: [].}

  BlockExcEngine* = ref object of RootObj
    localStore*: BlockStore
    network*: BlockExcNetwork
    peers*: PeerCtxStore
    taskQueue*: AsyncHeapQueue[BlockExcPeerCtx]
    selectPeer*: PeerSelector
    concurrentTasks: int
    trackedFutures: TrackedFutures
    blockexcRunning: bool
    maxBatchBlocks: int
    discoveryDeadline*: Duration
    blockRequestTimeout: Duration
    pendingBlocks*: PendingBlocksManager
    discovery*: DiscoveryEngine
    advertiser*: Advertiser
    lastDiscRequest: Moment

proc scheduleTask(self: BlockExcEngine, task: BlockExcPeerCtx) {.gcsafe, raises: [].} =
  # Only stamp on first enqueue; pushOrUpdateNoWait must not reset wait clock.
  if task.taskEnqueuedAt == default(Moment):
    task.taskEnqueuedAt = Moment.now()
  if self.taskQueue.pushOrUpdateNoWait(task).isOk():
    archivist_block_exchange_task_queue_depth.set(self.taskQueue.len.int64)
    trace "Task scheduled for peer", peer = task.id
  else:
    archivist_block_exchange_task_queue_full.inc()
    # Leave taskEnqueuedAt set — peer still waiting or will be re-scheduled.
    warn "Unable to schedule task for peer", peer = task.id

proc blockexcTaskRunner(self: BlockExcEngine) {.async: (raises: []).}

proc resolveBlocks*(
  self: BlockExcEngine, blocksDelivery: seq[BlockDelivery], sender: ?BlockExcPeerCtx
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

  self.trackedFutures.track(self.pendingBlocks.start())

proc stop*(self: BlockExcEngine) {.async: (raises: []).} =
  if not self.blockexcRunning:
    warn "Stopping blockexc without starting it"
    return

  self.blockexcRunning = false
  await self.trackedFutures.cancelTracked()
  await self.pendingBlocks.stop()
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
  archivist_block_exchange_want_block_entries_sent.inc(addresses.len.int64)

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
    archivist_block_exchange_want_have_lists_sent.inc()
    archivist_block_exchange_want_have_entries_sent.inc(batch.len.int64)

    offset = batchEnd

proc refreshBlockKnowledge(
    self: BlockExcEngine, peer: BlockExcPeerCtx
): Future[?Duration] {.async: (raises: [CancelledError]).} =
  if self.pendingBlocks.wantListLen == 0:
    return Duration.none

  let peerHave = peer.peerHave
  var wantList = initHashSet[BlockAddress]()
  for address in self.pendingBlocks.wantList:
    if address notin peerHave:
      wantList.incl(address)

  if wantList.len == 0:
    return Duration.none

  let decision = peer.decideSend(wantList)
  case decision.kind
  of SendKind.None:
    return decision.wakeAfter
  of SendKind.Full:
    await self.sendBatchedWantList(peer, decision.wants.toSeq, full = true)
    return Duration.none
  of SendKind.Delta:
    await self.sendBatchedWantList(peer, decision.wants.toSeq, full = false)
    return Duration.none

proc minWakeHint(current: var Option[Duration], candidate: Option[Duration]) =
  if wake =? candidate:
    if existing =? current:
      if wake < existing:
        current = wake.some
    else:
      current = wake.some

proc searchForNewPeers(self: BlockExcEngine, cid: Cid) =
  if self.lastDiscRequest + DiscoveryRateLimit < Moment.now():
    archivist_block_exchange_discovery_requests.inc()
    self.lastDiscRequest = Moment.now()
    self.discovery.queueFindBlocksReq(@[cid])

proc evictPeer(self: BlockExcEngine, peer: PeerId) {.gcsafe, async: (raises: []).} =
  trace "Evicting disconnected/departed peer", peer
  # Just remove from store - disconnect monitor in PendingBlocksManager handles requeue
  self.peers.remove(peer)

proc topPeersForCid*(self: BlockExcEngine, cid: Cid, topK: int): seq[BlockExcPeerCtx] =
  let candidates = self.peers.peersHave(cid)
  if candidates.len == 0:
    return @[]
  let ranked = rankPeersByScore(candidates, cid)
  if ranked.len == 0:
    return @[]
  ranked[0 ..< min(topK, ranked.len)]

proc topPeersByAggregate*(self: BlockExcEngine, topK: int): seq[BlockExcPeerCtx] =
  let allPeers = toSeq(self.peers.peers.values)
  let ranked = rankPeersByAggregate(allPeers)
  if ranked.len == 0:
    return @[]
  ranked[0 ..< min(topK, ranked.len)]

proc failBlockRequest(
    self: BlockExcEngine,
    address: BlockAddress,
    errType: typedesc[EngineError],
    msg: string,
) {.async: (raises: []).} =
  await self.pendingBlocks.failWantHandle(address, errType, msg)

proc requestDeliveries*(
    self: BlockExcEngine, addresses: seq[BlockAddress], priority = 0
): ?!seq[BlockHandle] =
  var handles: seq[BlockHandle]

  for address in addresses.deduplicate():
    handles.add(self.pendingBlocks.getWantHandle(address, priority = priority))

  success handles

proc requestDelivery*(
    self: BlockExcEngine, address: BlockAddress, priority = 0
): ?!BlockHandle =
  success self.pendingBlocks.getWantHandle(address, priority = priority)

proc completeBlocks*(
    self: BlockExcEngine, blocksDelivery: seq[BlockDelivery]
) {.async: (raises: [CancelledError]).} =
  await self.resolveBlocks(blocksDelivery, BlockExcPeerCtx.none)

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

  for blk in blocks:
    if presence =? Presence.init(blk):
      peerCtx.setPresence(presence)

  let
    peerHave = peerCtx.peerHave
    dontWantCids = peerHave - ourWantList

  if dontWantCids.len > 0:
    peerCtx.cleanPresence(dontWantCids.toSeq)

  var toRetry: seq[BlockAddress]
  for address in ourWantList:
    if address in peerHave and not self.pendingBlocks.retriesExhausted(address) and
        not self.pendingBlocks.isRequested(address):
      toRetry.add(address)

  for address in toRetry:
    discard self.pendingBlocks.wakeAddress(address)

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
  let toCancel = toHashSet(addrs)
  var scheduledCancellations: Table[PeerId, HashSet[BlockAddress]]

  if self.peers.len == 0:
    return

  proc dispatchCancellations(
      peerId: PeerId, addresses: HashSet[BlockAddress]
  ): Future[PeerId] {.async: (raises: [CancelledError]).} =
    await self.network.request.sendWantCancellations(peerId, addresses.toSeq)
    peerId

  for peerCtx in self.peers.peers.values:
    let intersection = peerCtx.blocksRequested.intersection(toCancel)
    if intersection.len > 0:
      scheduledCancellations[peerCtx.id] = intersection
      peerCtx.cleanPresence(addrs)

  if scheduledCancellations.len == 0:
    return

  var futures: seq[Future[PeerId]]
  for peerId, addresses in scheduledCancellations:
    futures.add(dispatchCancellations(peerId, addresses))

  let (_, failedFuts) = await allFinishedFailed[PeerId](futures)
  if failedFuts.len > 0:
    warn "Failed to send block request cancellations to peers", peers = failedFuts.len

proc resolveBlocks*(
    self: BlockExcEngine, blocksDelivery: seq[BlockDelivery], sender: ?BlockExcPeerCtx
) {.async: (raises: [CancelledError]).} =
  await self.pendingBlocks.resolve(blocksDelivery, sender)
  await self.scheduleTasks(blocksDelivery)
  await self.cancelBlocks(blocksDelivery.mapIt(it.address))

proc resolveBlocks*(
    self: BlockExcEngine, blocks: seq[Block]
) {.async: (raises: [CancelledError]).} =
  await self.resolveBlocks(
    blocks.mapIt(
      BlockDelivery(blk: it, address: BlockAddress(leaf: false, cid: it.cid))
    ),
    BlockExcPeerCtx.none,
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
    self: BlockExcEngine, peer: PeerId, blocksDelivery: seq[BlockDelivery]
) {.async: (raises: [CancelledError]).} =
  trace "Received blocks from peer", peer, count = blocksDelivery.len

  var
    validatedBlocksDelivery: seq[BlockDelivery]
    leafByTree: Table[Cid, seq[(Block, Natural, ArchivistProof)]]
    nonLeafDeliveries: seq[BlockDelivery]
    acceptedAddresses: seq[BlockAddress]
    lastIdle = Moment.now()

  let
    peerCtx = self.peers.get(peer)
    runtimeQuota = 10.milliseconds

  for bd in blocksDelivery:
    logScope:
      peer = peer
      address = bd.address

    try:
      if bd.address notin self.pendingBlocks:
        archivist_block_exchange_spurious_blocks_received.inc()
        trace "Block is not pending", address = bd.address
        continue

      if err =? self.validateBlockDelivery(bd).errorOption:
        warn "Block validation failed", msg = err.msg
        if not peerCtx.isNil:
          peerCtx.cleanPresence(bd.address)
          # Always record validation failure: invalid data from any peer
          # is a quality signal, regardless of assignment.
          peerCtx.recordFailure(bd.address.cidOrTreeCid, isValidation = true)
          if self.pendingBlocks.rejectRequest(bd.address, peerCtx):
            archivist_block_exchange_requests_retried.inc(
              labelValues = [$(RetryReason.Validation), ""]
            )
            self.pendingBlocks.recordRetryOutcome(@[bd.address])
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
        peerCtx.cleanPresence(bd.address)
        if self.pendingBlocks.rejectRequest(bd.address, peerCtx):
          archivist_block_exchange_requests_retried.inc(
            labelValues = [$(RetryReason.Validation), ""]
          )
          self.pendingBlocks.recordRetryOutcome(@[bd.address])
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
      peerCtx.cleanPresence(address)

  archivist_block_exchange_blocks_received.inc(validatedBlocksDelivery.len.int64)
  var totalBytesReceived = 0
  for bd in validatedBlocksDelivery:
    totalBytesReceived += bd.blk.data.len
  archivist_block_exchange_bytes_received.inc(totalBytesReceived.int64)

  await self.resolveBlocks(validatedBlocksDelivery, peerCtx.option)

proc wantListHandler*(
    self: BlockExcEngine, peer: PeerId, wantList: WantList
) {.async: (raises: []).} =
  trace "Received want list from peer", peer, wantList = wantList.entries.len

  let peerCtx = self.peers.get(peer)
  if peerCtx.isNil:
    return
  var
    wantHaveCount = 0
    wantBlockCount = 0
  for e in wantList.entries:
    if e.cancel:
      continue
    case e.wantType
    of WantType.WantHave:
      inc wantHaveCount
    of WantType.WantBlock:
      inc wantBlockCount
  if wantHaveCount > 0:
    archivist_block_exchange_want_have_lists_received.inc()
    archivist_block_exchange_want_have_entries_received.inc(wantHaveCount.int64)
  if wantBlockCount > 0:
    archivist_block_exchange_want_block_lists_received.inc()
    archivist_block_exchange_want_block_entries_received.inc(wantBlockCount.int64)

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
      of WantType.WantBlock:
        peerCtx.wantedBlocks.incl(e.address)
        schedulePeer = true

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
  discard await self.refreshBlockKnowledge(peerCtx)

proc taskHandler*(
    self: BlockExcEngine, peerCtx: BlockExcPeerCtx
) {.gcsafe, async: (raises: [CancelledError]).} =
  let wantedBlocks = peerCtx.wantedBlocks.toSeq.filterIt(not peerCtx.isBlockSent(it))
  if wantedBlocks.len == 0:
    peerCtx.taskEnqueuedAt = default(Moment)
    return

  # Queue wait: scheduleTask → worker start. High wait + low service => capacity.
  if peerCtx.taskEnqueuedAt != default(Moment):
    let wait = Moment.now() - peerCtx.taskEnqueuedAt
    if wait.nanoseconds > 0:
      archivist_block_exchange_task_queue_wait_seconds.observe(
        wait.nanoseconds.float64 / 1e9
      )
  peerCtx.taskEnqueuedAt = default(Moment)
  archivist_block_exchange_task_queue_depth.set(self.taskQueue.len.int64)
  archivist_block_exchange_active_serve_tasks.inc()

  for address in wantedBlocks:
    peerCtx.markBlockAsSent(address)

  var deliveredAddresses = initHashSet[BlockAddress]()

  proc loadSlice(
      slice: seq[BlockAddress]
  ): Future[seq[BlockDelivery]] {.async: (raises: [CancelledError]).} =
    var
      leafIndicesByTree: Table[Cid, seq[Natural]]
      nonLeafAddresses: seq[BlockAddress]
      blockDeliveries: seq[BlockDelivery]

    for wantedBlock in slice:
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
        return @[]

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

    blockDeliveries

  proc sendSlice(batch: seq[BlockDelivery]) {.async: (raises: [CancelledError]).} =
    if batch.len == 0:
      return
    await self.network.request.sendBlocksDelivery(peerCtx.id, batch)
    archivist_block_exchange_blocks_sent.inc(batch.len.int64)
    var batchBytes = 0
    for delivery in batch:
      batchBytes += delivery.blk.data.len
      deliveredAddresses.incl(delivery.address)
    archivist_block_exchange_bytes_sent.inc(batchBytes.int64)

  try:
    # Pipeline: load slice N+1 while send of slice N is in flight (NET_WRITE overlap).
    # Single TCP stream per peer still serializes writes; store work no longer waits.
    var
      totalStoreNs = 0'i64
      totalSendNs = 0'i64
      pendingSend: Future[void].Raising([CancelledError])
      pendingSendStart = Moment.now()

    try:
      var offset = 0
      while offset < wantedBlocks.len:
        let
          batchEnd = min(offset + self.maxBatchBlocks, wantedBlocks.len)
          slice = wantedBlocks[offset ..< batchEnd]
        offset = batchEnd

        # Store-read runs concurrent with any prior pendingSend.
        let storeReadStart = Moment.now()
        let blockDeliveries = await loadSlice(slice)
        totalStoreNs += (Moment.now() - storeReadStart).nanoseconds

        if not pendingSend.isNil:
          await pendingSend
          totalSendNs += (Moment.now() - pendingSendStart).nanoseconds
          pendingSend = nil

        if blockDeliveries.len == 0:
          continue

        pendingSendStart = Moment.now()
        pendingSend = sendSlice(blockDeliveries)

      if not pendingSend.isNil:
        await pendingSend
        totalSendNs += (Moment.now() - pendingSendStart).nanoseconds
        pendingSend = nil
    finally:
      if not pendingSend.isNil:
        await noCancel pendingSend.cancelAndWait()

    if totalStoreNs > 0:
      archivist_block_exchange_task_store_read_seconds.observe(
        totalStoreNs.float64 / 1e9
      )
    if totalSendNs > 0:
      archivist_block_exchange_task_send_seconds.observe(totalSendNs.float64 / 1e9)

    for address in deliveredAddresses:
      peerCtx.wantedBlocks.excl(address)
  finally:
    archivist_block_exchange_active_serve_tasks.dec()
    var wantedTotal = 0
    for p in self.peers:
      wantedTotal += p.wantedBlocks.len
    archivist_block_exchange_wanted_blocks.set(wantedTotal.int64)

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
      archivist_block_exchange_task_queue_depth.set(self.taskQueue.len.int64)
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
    maxBatchBlocks = DefaultMaxBatchBlocks,
    concurrentTasks = DefaultConcurrentTasks,
    selectPeer: PeerSelector = scoredPeer,
    blockRequestTimeout = DefaultRequestTimeout,
): BlockExcEngine =
  let self = BlockExcEngine(
    localStore: localStore,
    peers: peerStore,
    pendingBlocks: pendingBlocks,
    network: network,
    concurrentTasks: concurrentTasks,
    trackedFutures: TrackedFutures(),
    maxBatchBlocks: maxBatchBlocks,
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

  proc onAbandonHandler(
      address: BlockAddress
  ) {.gcsafe, async: (raises: [CancelledError]).} =
    trace "Running abandon block hook", address
    await self.cancelBlocks(@[address])

  proc onTimeoutHandler(
      address: BlockAddress, peer: PeerId
  ) {.gcsafe, async: (raises: [CancelledError]).} =
    trace "Block request timed out", address, peer
    archivist_block_exchange_peer_timeouts.inc()
    # Don't drop the peer — a single block timeout doesn't mean
    # the peer is bad. pendingBlocks already retries the block.

  # Must call self.selectPeer so tests can inject a custom selector.
  # Load-balance among top-K scored peers lives in scoredPeer (default).
  proc selectKnownPeer(address: BlockAddress): BlockExcPeerCtx {.gcsafe, raises: [].} =
    let peers = self.peers.getPeersForBlock(address)
    if peers.with.len == 0:
      return nil
    self.selectPeer(peers.with, address)

  proc pendingPeerSelector(
      address: BlockAddress
  ): Future[?!PeerSelection] {.async: (raises: [CancelledError]), gcsafe.} =
    let localPeer = selectKnownPeer(address)
    if not localPeer.isNil:
      return success PeerSelection(kind: PeerSelectionKind.Peer, peer: localPeer)

    let
      cid = address.cidOrTreeCid
      candidates = self.peers.peersHave(cid)
      topPeers =
        if candidates.len > 0:
          let ranked = rankPeersByScore(candidates, cid)
          if ranked.len == 0:
            @[]
          else:
            ranked[0 ..< min(DefaultWantHaveTopK, ranked.len)]
        else:
          self.topPeersByAggregate(DefaultWantHaveTopK)

    var minWake = Duration.none
    if topPeers.len > 0:
      let futs = topPeers.mapIt(self.refreshBlockKnowledge(it))
      for fut in await allFinished(futs):
        if fut.completed():
          try:
            minWakeHint(minWake, fut.read())
          except CatchableError:
            discard

    let discoveredPeer = selectKnownPeer(address)
    if not discoveredPeer.isNil:
      return success PeerSelection(kind: PeerSelectionKind.Peer, peer: discoveredPeer)

    if self.peers.peersHave(cid).len == 0:
      self.searchForNewPeers(cid)

    if wake =? minWake:
      return success PeerSelection(kind: PeerSelectionKind.Requeue, delay: wake)

    return success PeerSelection(kind: PeerSelectionKind.Requeue, delay: 0.seconds)

  proc onBatchReadyHandler(
      peer: BlockExcPeerCtx, batch: seq[BlockAddress]
  ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).} =
    if peer.isNil or batch.len == 0:
      trace "Either peer is missing or batch is empty",
        peerIsNil = peer.isNil, batch = batch.len
      return success()

    if err =? catchAsync(await self.sendWantBlock(batch, peer.id)).errorOption:
      peer.cleanPresence(batch)
      trace "Error sending batch", err = err.msg
      return failure(err)

    success()

  pendingBlocks.getPeerForBlock = pendingPeerSelector
  pendingBlocks.sendBatch = onBatchReadyHandler

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
