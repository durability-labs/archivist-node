## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/sequtils
import pkg/chronos
import pkg/libp2p/cid
import pkg/libp2p/multicodec
import ./metrics
import pkg/questionable
import pkg/questionable/results

import ../protobuf/presence
import ../peers

import ../../utils
import ../../utils/exceptions
import ../../utils/trackedfutures
import ../../discovery
import ../../stores/blockstore
import ../../logutils
import ../../manifest

logScope:
  topics = "archivist discoveryengine advertiser"

const
  DefaultConcurrentAdvertRequests = 10
  DefaultAdvertiseLoopSleep = 30.minutes
  DefaultMinAdvertisePeers = 16
  DefaultAdvertiseRetrySleep = 30.seconds
  DefaultAdvertiseRetryWindow = 10.minutes

type Advertiser* = ref object of RootObj
  localStore*: BlockStore # Local block store for this instance
  discovery*: Discovery # Discovery interface

  advertiserRunning*: bool # Indicates if discovery is running
  concurrentAdvReqs: int # Concurrent advertise requests

  advertiseLocalStoreLoop*: Future[void].Raising([]) # Advertise loop task handle
  advertiseQueue*: AsyncQueue[Cid] # Advertise queue
  trackedFutures*: TrackedFutures # Advertise tasks futures

  advertiseLocalStoreLoopSleep: Duration # Advertise loop sleep
  inFlightAdvReqs*: Table[Cid, Future[void]] # Inflight advertise requests
  pendingAdvRetries: Table[Cid, Future[void]] # Delayed sparse retry tasks
  minAdvertisePeers: int # Desired routing-table size before advertising
  advertiseRetrySleep: Duration # Delay before retrying sparse startup advertise
  advertiseRetryWindow: Duration # Startup window for sparse advertise retries
  startedAt: Moment # Time advertiser started

proc addCidToQueue(b: Advertiser, cid: Cid) {.async: (raises: [CancelledError]).} =
  if cid notin b.advertiseQueue:
    await b.advertiseQueue.put(cid)

    trace "Advertising", cid

proc advertiseBlock(b: Advertiser, cid: Cid) {.async: (raises: [CancelledError]).} =
  without isM =? cid.isManifest, err:
    warn "Unable to determine if cid is manifest"
    return

  try:
    if isM:
      without blk =? await b.localStore.getBlock(cid), err:
        error "Error retrieving manifest block", cid, err = err.msg
        return

      without manifest =? Manifest.decode(blk), err:
        error "Unable to decode as manifest", err = err.msg
        return

      # announce manifest cid and tree cid
      await b.addCidToQueue(cid)
      await b.addCidToQueue(manifest.treeCid)
  except CancelledError as exc:
    trace "Cancelled advertise block", cid
    raise exc
  except CatchableError as e:
    error "failed to advertise block", cid, error = e.msgDetail

proc advertiseLocalStoreLoop(b: Advertiser) {.async: (raises: []).} =
  try:
    while b.advertiserRunning:
      without cidsIter =? await b.localStore.listBlocks(blockType = BlockType.Manifest),
        err:
        trace "Error retrieving manifest iterator, advertising skipped!", err = err.msg
        await sleepAsync(b.advertiseLocalStoreLoopSleep)
        continue

      defer:
        if err =? (await cidsIter.dispose()).errorOption:
          warn "Error disposing manifest iterator", err = err.msg

      trace "Advertiser begins iterating blocks..."
      for c in cidsIter:
        if cid =? await c:
          await b.advertiseBlock(cid)
      trace "Advertiser iterating blocks finished."

      await sleepAsync(b.advertiseLocalStoreLoopSleep)
  except CancelledError:
    warn "Cancelled advertise local store loop"

  info "Exiting advertise task loop"

proc hasElapsed(since: Moment, dur: Duration): bool =
  (Moment.now() - since) >= dur

proc shouldRetryAdvertise(b: Advertiser): bool =
  b.minAdvertisePeers > 0 and b.discovery.nodesDiscovered() < b.minAdvertisePeers and
    not hasElapsed(b.startedAt, b.advertiseRetryWindow)

proc delayedAdvertiseRetry(b: Advertiser, cid: Cid) {.async: (raises: []).} =
  try:
    await sleepAsync(b.advertiseRetrySleep)

    if b.advertiserRunning and not hasElapsed(b.startedAt, b.advertiseRetryWindow):
      trace "Requeueing advertisement retry",
        cid, nodes = b.discovery.nodesDiscovered(), target = b.minAdvertisePeers
      await b.addCidToQueue(cid)
  except CancelledError:
    trace "Cancelled sparse startup advertisement retry", cid
  except CatchableError as exc:
    warn "Sparse startup advertisement retry failed", cid, err = exc.msg
  finally:
    b.pendingAdvRetries.del(cid)

proc scheduleAdvertiseRetry(b: Advertiser, cid: Cid) =
  if cid in b.pendingAdvRetries:
    return

  let retry = b.delayedAdvertiseRetry(cid)
  b.pendingAdvRetries[cid] = retry
  b.trackedFutures.track(retry)

proc processQueueLoop(b: Advertiser) {.async: (raises: []).} =
  try:
    while b.advertiserRunning:
      let cid = await b.advertiseQueue.get()

      if cid in b.inFlightAdvReqs:
        continue

      let request = b.discovery.provide(cid)
      b.inFlightAdvReqs[cid] = request
      archivist_inflight_advertise.set(b.inFlightAdvReqs.len.int64)

      try:
        await request
      finally:
        b.inFlightAdvReqs.del(cid)
        archivist_inflight_advertise.set(b.inFlightAdvReqs.len.int64)

      if b.shouldRetryAdvertise():
        b.scheduleAdvertiseRetry(cid)
  except CancelledError:
    warn "Cancelled advertise task runner"

  await noCancel allFutures(toSeq(b.inFlightAdvReqs.values).mapIt(it.cancelAndWait()))

  info "Exiting advertise task runner"

proc start*(b: Advertiser) {.async: (raises: []).} =
  ## Start the advertiser
  ##

  trace "Advertiser start"

  # The advertiser is expected to be started only once.
  if b.advertiserRunning:
    warn "Advertiser can only be started once - this should not happen"
    return

  b.advertiserRunning = true

  proc onBlock(cid: Cid) {.async: (raises: []).} =
    try:
      await b.advertiseBlock(cid)
    except CancelledError:
      trace "Cancelled advertise block", cid

  doAssert(b.localStore.onBlockStored.isNone())
  b.localStore.onBlockStored = onBlock.some

  b.startedAt = Moment.now()
  for i in 0 ..< b.concurrentAdvReqs:
    let fut = b.processQueueLoop()
    b.trackedFutures.track(fut)

  b.advertiseLocalStoreLoop = advertiseLocalStoreLoop(b)
  b.trackedFutures.track(b.advertiseLocalStoreLoop)

proc stop*(b: Advertiser) {.async: (raises: []).} =
  ## Stop the advertiser
  ##

  trace "Advertiser stop"
  if not b.advertiserRunning:
    warn "Stopping advertiser without starting it"
    return

  trace "Stopping advertise loop and tasks"
  await b.trackedFutures.cancelTracked()

  b.advertiserRunning = false
  # Stop incoming tasks from callback and localStore loop
  b.localStore.onBlockStored = CidCallback.none
  trace "Advertiser loop and tasks stopped"

proc new*(
    T: type Advertiser,
    localStore: BlockStore,
    discovery: Discovery,
    concurrentAdvReqs = DefaultConcurrentAdvertRequests,
    advertiseLocalStoreLoopSleep = DefaultAdvertiseLoopSleep,
    minAdvertisePeers = DefaultMinAdvertisePeers,
    advertiseRetrySleep = DefaultAdvertiseRetrySleep,
    advertiseRetryWindow = DefaultAdvertiseRetryWindow,
): Advertiser =
  ## Create a advertiser instance
  ##
  Advertiser(
    localStore: localStore,
    discovery: discovery,
    concurrentAdvReqs: concurrentAdvReqs,
    advertiseQueue: newAsyncQueue[Cid](concurrentAdvReqs),
    trackedFutures: TrackedFutures.new(),
    inFlightAdvReqs: initTable[Cid, Future[void]](),
    pendingAdvRetries: initTable[Cid, Future[void]](),
    advertiseLocalStoreLoopSleep: advertiseLocalStoreLoopSleep,
    minAdvertisePeers: minAdvertisePeers,
    advertiseRetrySleep: advertiseRetrySleep,
    advertiseRetryWindow: advertiseRetryWindow,
  )
