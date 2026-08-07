## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## Store maintenance module
## Scans overlays for expiration and drops expired ones.

{.push raises: [].}

import std/sequtils

import pkg/chronos
import pkg/questionable
import pkg/questionable/results

import ./repostore
import ../utils/timer
import ../clock
import ../logutils
import ../systemclock
import ../errors

logScope:
  topics = "archivist maintenance"

const
  DefaultBlockInterval* = 10.minutes
  DefaultNumBlocksPerInterval* = 1000
  DefaultMaxConcurrentOverlayDrops* = 5

type BlockMaintainer* = ref object of RootObj
  repoStore: RepoStore
  interval: Duration
  maxConcurrent: int
  timer: Timer
  clock: Clock

proc new*(
    T: type BlockMaintainer,
    repoStore: RepoStore,
    interval: Duration,
    maxConcurrent = DefaultMaxConcurrentOverlayDrops,
    timer = Timer.new("maintenance"),
    clock: Clock = SystemClock.new(),
): BlockMaintainer =
  ## Create new BlockMaintainer instance
  ##
  ## Call `start` to begin scanning for expired overlays
  ##
  BlockMaintainer(
    repoStore: repoStore,
    interval: interval,
    maxConcurrent: maxConcurrent,
    timer: timer,
    clock: clock,
  )

proc dropAndLog(
    self: BlockMaintainer, treeCid: Cid, status: OverlayStatus
): Future[void] {.async: (raises: [CancelledError]).} =
  trace "Dropping overlay", treeCid, status
  if err =? (await self.repoStore.dropOverlay(treeCid)).errorOption:
    error "Error dropping overlay", treeCid, status, err = err.msg

proc dropExpiredOverlays(
    self: BlockMaintainer
): Future[void] {.async: (raises: [CancelledError]).} =
  without overlays =? (
    await self.repoStore.listOverlaysByExpiry(limit = -1, offset = 0)
  ), err:
    warn "Unable to list overlays", err = err.msg
    return

  let now = self.clock.now
  var inFlight: seq[Future[void]]

  for (treeCid, meta) in overlays:
    # Deleting - finish cleanup, if delete in progress, dropOverlay will
    # no-op
    # Failure - always drop
    # Any other status - check expiry
    let shouldDrop =
      meta.status == Deleting or meta.status == Failure or
      (meta.expiry > 0 and meta.expiry < now)

    if shouldDrop:
      # Wait for a slot if at capacity
      if inFlight.len >= self.maxConcurrent:
        without completedFut =? catchAsync(await one(inFlight)), err:
          error "Error waiting for overlay drop", err = err.msg
          break
        inFlight.keepItIf(it != completedFut)

      inFlight.add(self.dropAndLog(treeCid, meta.status))

  # Drain remaining in-flight deletions
  await noCancel allFutures(inFlight)

proc start*(self: BlockMaintainer) =
  proc onTimer(): Future[void] {.async: (raises: []).} =
    try:
      await self.dropExpiredOverlays()
    except CancelledError as err:
      trace "Maintenance timer callback cancelled", err = err.msg

  self.timer.start(onTimer, self.interval)

proc stop*(self: BlockMaintainer): Future[void] {.async: (raises: []).} =
  await self.timer.stop()
