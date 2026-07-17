## Chronos future tracking observer
##
## Two-cadence design:
## - Fast (100ms): lightweight loop-lag histogram only
## - Slow (2s): pending count, oldest age
## - Site scan (30s): creation-site aggregation
##
## Requires -d:chronosFutureTracking for site tracking.
## Spawned explicitly from archivist/archivist.nim NodeServer.start().

{.push raises: [CancelledError].}

import std/[tables, algorithm, sequtils]
import pkg/chronos
import pkg/chronos/debugutils
import pkg/metrics
import pkg/chronicles

logScope:
  topics = "archivist chronos_observer"

declarePublicGauge(
  archivist_chronos_pending_futures, "Number of pending chronos futures"
)
declarePublicGauge(
  archivist_chronos_pending_futures_oldest_age_seconds,
  "Age of oldest pending future (seconds)",
)
declarePublicHistogram(
  archivist_chronos_loop_lag_seconds,
  "Observer timer overshoot / resume latency (seconds)",
  buckets = @[0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.0, 5.0],
)

type ObserverState = ref object
  firstSeen: Table[uint64, Moment]

proc updateMetrics(state: ObserverState, logSites: bool) =
  when defined(chronosFutureTracking):
    let now = Moment.now()
    var
      pending = 0
      oldest = 0.0
      sites: Table[string, int]

    for item in pendingFutures():
      if item.state == FutureState.Pending:
        inc(pending)
        if item.id notin state.firstSeen:
          state.firstSeen[item.id] = now
        let ts = state.firstSeen.getOrDefault(item.id, now)
        let age = (now - ts).nanoseconds.float64 / 1e9
        if age > oldest:
          oldest = age
        if logSites:
          let loc = item.location[LocationKind.Create]
          if not loc.isNil:
            let key = $loc.procedure & "<" & $loc.file & ":" & $loc.line & ">"
            sites.mgetOrPut(key, 0).inc()

    archivist_chronos_pending_futures.set(pending.float64)
    archivist_chronos_pending_futures_oldest_age_seconds.set(oldest)

    if logSites and sites.len > 0:
      var top = toSeq(sites.pairs)
      top.sort(
        proc(a, b: (string, int)): int =
          cmp(b[1], a[1])
      )
      var summary = ""
      for i in 0 ..< min(15, top.len):
        summary.add(top[i][0] & "=" & $top[i][1] & " ")
      info "Pending future creation sites", pending, sites = summary

    if state.firstSeen.len > 4096:
      var toDelete: seq[uint64] = @[]
      for id, ts in state.firstSeen:
        if (now - ts).nanoseconds.float64 / 1e9 > 60.0:
          toDelete.add(id)
      for id in toDelete:
        state.firstSeen.del(id)

proc chronosObserver*(interval: Duration = 1.seconds) {.async: (raises: []).} =
  let state = ObserverState(firstSeen: initTable[uint64, Moment]())
  info "Chronos observer started", interval = interval

  # Fast lag timer: 100ms
  proc lagLoop() {.async: (raises: []).} =
    while true:
      try:
        let sleepStart = Moment.now()
        await sleepAsync(100.millis)
        let lag = (Moment.now() - sleepStart - 100.millis).nanoseconds.float64 / 1e9
        archivist_chronos_loop_lag_seconds.observe(max(lag, 0.0))
      except CancelledError:
        break

  asyncSpawn lagLoop()

  # Slow metrics cadence
  var slowTick = 0
  while true:
    try:
      await sleepAsync(interval)
    except CancelledError:
      break
    inc(slowTick)
    try:
      updateMetrics(state, logSites = (slowTick mod 15 == 0))
    except CatchableError as exc:
      warn "Chronos observer error", err = exc.msg
