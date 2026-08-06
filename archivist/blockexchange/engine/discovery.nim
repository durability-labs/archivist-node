## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils
import std/sets

import pkg/chronos
import pkg/libp2p/cid
import pkg/libp2p/multicodec
import ./metrics
import pkg/questionable
import pkg/questionable/results

import ./pendingblocks

import ../protobuf/presence
import ../network
import ../peers

import ../../utils
import ../../utils/trackedfutures
import ../../discovery
import ../../stores/blockstore
import ../../logutils
import ../../manifest

logScope:
  topics = "archivist discoveryengine"

const
  DefaultConcurrentDiscRequests = 10
  DefaultDiscoveryTimeout = 1.minutes
  DefaultMinPeersPerBlock = 3
  DefaultDiscoveryLoopSleep = 3.seconds
  DefaultDiscoverBackoffBase = 3.seconds
  DefaultDiscoverBackoffMax = 60.seconds
  DefaultDiscoverBackoffMaxMult = 5
    # base << 5 (96s) exceeds the 60s cap, so the interval saturates there

type DiscoveryEngine* = ref object of RootObj
  localStore*: BlockStore # Local block store for this instance
  peers*: PeerCtxStore # Peer context store
  network*: BlockExcNetwork # Network interface
  discovery*: Discovery # Discovery interface
  pendingBlocks*: PendingBlocksManager # Blocks we're awaiting to be resolved
  discEngineRunning*: bool # Indicates if discovery is running
  concurrentDiscReqs: int # Concurrent discovery requests
  discoveryLoop*: Future[void].Raising([]) # Discovery loop task handle
  discoveryQueue*: AsyncQueue[Cid] # Discovery queue
  trackedFutures*: TrackedFutures # Tracked Discovery tasks futures
  minPeersPerBlock*: int # Max number of peers with block
  discoveryLoopSleep: Duration # Discovery loop sleep
  discoverBackoffBase: Duration # Backoff base for failed discovery requests
  discoverBackoffMax: Duration # Backoff cap for failed discovery requests
  inFlightDiscReqs*: Table[Cid, Future[seq[SignedPeerRecord]]]
    # Inflight discovery requests
  discoverBackoff: Table[Cid, tuple[due: Moment, mult: int]]
    # Earliest retry time and backoff multiplier per CID

proc discoveryQueueLoop(b: DiscoveryEngine) {.async: (raises: []).} =
  try:
    while b.discEngineRunning:
      # Drop backoff state for blocks that are no longer wanted - the table
      # must not grow with every cid ever queued. wantListCids covers leaf
      # wants' tree cids, which also get discovery finds (searchForNewPeers).
      let wanted = toHashSet(toSeq(b.pendingBlocks.wantListCids))
      for cid in toSeq(b.discoverBackoff.keys):
        if cid notin wanted:
          b.discoverBackoff.del(cid)

      for cid in toSeq(b.pendingBlocks.wantListBlockCids):
        await b.discoveryQueue.put(cid)

      await sleepAsync(b.discoveryLoopSleep)
  except CancelledError:
    trace "Discovery loop cancelled"

proc nextDiscoverBackoff(b: DiscoveryEngine, cid: Cid) {.raises: [].} =
  ## Advance the per-CID discovery backoff after a failed or empty find:
  ## increment the stored multiplier (capped at
  ## DefaultDiscoverBackoffMaxMult), then the next attempt is due in
  ## base * 2^mult, capped at discoverBackoffMax.
  var mult = 0
  b.discoverBackoff.withValue(cid, entry):
    mult = min(entry[].mult + 1, DefaultDiscoverBackoffMaxMult)
  let interval = min(b.discoverBackoffBase * (1 shl mult), b.discoverBackoffMax)
  b.discoverBackoff[cid] = (due: Moment.now() + interval, mult: mult)

proc discoveryTaskLoop(b: DiscoveryEngine) {.async: (raises: []).} =
  ## Run discovery tasks
  ##

  try:
    while b.discEngineRunning:
      let cid = await b.discoveryQueue.get()

      if cid in b.inFlightDiscReqs:
        trace "Discovery request already in progress", cid
        continue

      let haves = b.peers.peersHave(cid)
      if haves.len < b.minPeersPerBlock:
        var notDue = false
        b.discoverBackoff.withValue(cid, entry):
          notDue = Moment.now() < entry[].due
        if notDue:
          continue

        let request = b.discovery.find(cid)
        b.inFlightDiscReqs[cid] = request
        archivist_inflight_discovery.set(b.inFlightDiscReqs.len.int64)

        defer:
          b.inFlightDiscReqs.del(cid)
          archivist_inflight_discovery.set(b.inFlightDiscReqs.len.int64)

        if (await request.withTimeout(DefaultDiscoveryTimeout)) and
            peers =? (await request).catch:
          if peers.len > 0:
            b.discoverBackoff.del(cid)

            let dialed = await allFinished(peers.mapIt(b.network.dialPeer(it.data)))
            for i, f in dialed:
              if f.failed:
                await b.discovery.removeProvider(peers[i].data.peerId)
          else:
            b.nextDiscoverBackoff(cid)
        else:
          b.nextDiscoverBackoff(cid)
  except CancelledError:
    trace "Discovery task cancelled"
    return

  info "Exiting discovery task runner"

proc queueFindBlocksReq*(b: DiscoveryEngine, cids: seq[Cid]) =
  for cid in cids:
    if cid notin b.discoveryQueue:
      try:
        b.discoveryQueue.putNoWait(cid)
      except CatchableError as exc:
        warn "Exception queueing discovery request", exc = exc.msg

proc start*(b: DiscoveryEngine) {.async: (raises: []).} =
  ## Start the discengine task
  ##

  trace "Discovery engine starting"

  if b.discEngineRunning:
    warn "Starting discovery engine twice"
    return

  b.discEngineRunning = true
  for i in 0 ..< b.concurrentDiscReqs:
    let fut = b.discoveryTaskLoop()
    b.trackedFutures.track(fut)

  b.discoveryLoop = b.discoveryQueueLoop()
  b.trackedFutures.track(b.discoveryLoop)

  trace "Discovery engine started"

proc stop*(b: DiscoveryEngine) {.async: (raises: []).} =
  ## Stop the discovery engine
  ##

  trace "Discovery engine stop"
  if not b.discEngineRunning:
    warn "Stopping discovery engine without starting it"
    return

  b.discEngineRunning = false
  trace "Stopping discovery loop and tasks"
  await b.trackedFutures.cancelTracked()
  trace "Discovery loop and tasks stopped"

  trace "Discovery engine stopped"

proc new*(
    T: type DiscoveryEngine,
    localStore: BlockStore,
    peers: PeerCtxStore,
    network: BlockExcNetwork,
    discovery: Discovery,
    pendingBlocks: PendingBlocksManager,
    concurrentDiscReqs = DefaultConcurrentDiscRequests,
    discoveryLoopSleep = DefaultDiscoveryLoopSleep,
    minPeersPerBlock = DefaultMinPeersPerBlock,
    discoverBackoffBase = DefaultDiscoverBackoffBase,
    discoverBackoffMax = DefaultDiscoverBackoffMax,
): DiscoveryEngine =
  ## Create a discovery engine instance for advertising services
  ##
  DiscoveryEngine(
    localStore: localStore,
    peers: peers,
    network: network,
    discovery: discovery,
    pendingBlocks: pendingBlocks,
    concurrentDiscReqs: concurrentDiscReqs,
    discoveryQueue: newAsyncQueue[Cid](concurrentDiscReqs),
    trackedFutures: TrackedFutures.new(),
    inFlightDiscReqs: initTable[Cid, Future[seq[SignedPeerRecord]]](),
    discoveryLoopSleep: discoveryLoopSleep,
    minPeersPerBlock: minPeersPerBlock,
    discoverBackoffBase: discoverBackoffBase,
    discoverBackoffMax: discoverBackoffMax,
    discoverBackoff: initTable[Cid, tuple[due: Moment, mult: int]](),
  )
