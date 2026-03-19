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

import pkg/chronos
import pkg/questionable
import pkg/questionable/results

import ./repostore
import ../utils/timer
import ../utils/safeasynciter
import ../clock
import ../logutils
import ../systemclock

logScope:
  topics = "archivist maintenance"

const
  DefaultBlockInterval* = 10.minutes
  DefaultNumBlocksPerInterval* = 1000

type BlockMaintainer* = ref object of RootObj
  repoStore: RepoStore
  interval: Duration
  timer: Timer
  clock: Clock

proc new*(
    T: type BlockMaintainer,
    repoStore: RepoStore,
    interval: Duration,
    numberOfBlocksPerInterval = 100,
    timer = Timer.new("maintenance"),
    clock: Clock = SystemClock.new(),
): BlockMaintainer =
  ## Create new BlockMaintainer instance
  ##
  ## Call `start` to begin scanning for expired overlays
  ##
  BlockMaintainer(repoStore: repoStore, interval: interval, timer: timer, clock: clock)

proc dropExpiredOverlays(
    self: BlockMaintainer
): Future[void] {.async: (raises: [CancelledError]).} =
  without iter =? (await self.repoStore.listOverlays()), err:
    warn "Unable to list overlays", err = err.msg
    return

  defer:
    if err =? (await iter.dispose()).errorOption:
      warn "Error disposing overlay iterator", err = err.msg

  let now = self.clock.now

  for cidFut in iter:
    without treeCid =? (await cidFut), err:
      warn "Unable to get overlay CID from iterator", err = err.msg
      continue

    without meta =? (await self.repoStore.getOverlay(treeCid)), err:
      warn "Unable to get overlay metadata", treeCid, err = err.msg
      continue

    # Deleting - finish cleanup, if delete in progress, dropOverlay will
    # no-op
    # Failure - always drop
    # Any other status - check expiry
    let shouldDrop =
      meta.status == Deleting or meta.status == Failure or
      (meta.expiry > 0 and meta.expiry < now)

    if shouldDrop:
      trace "Dropping overlay", treeCid, status = meta.status, expiry = meta.expiry
      if err =? (await self.repoStore.dropOverlay(treeCid)).errorOption:
        error "Error dropping overlay", treeCid, status = meta.status, err = err.msg

    await sleepAsync(1.millis) # cooperative scheduling

proc start*(self: BlockMaintainer) =
  proc onTimer(): Future[void] {.async: (raises: []).} =
    try:
      await self.dropExpiredOverlays()
    except CancelledError as err:
      trace "Maintenance timer callback cancelled", err = err.msg

  self.timer.start(onTimer, self.interval)

proc stop*(self: BlockMaintainer): Future[void] {.async: (raises: []).} =
  await self.timer.stop()
