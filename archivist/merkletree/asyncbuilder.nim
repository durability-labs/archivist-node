## Copyright (c) 2025 Archivist Authors
## Licensed under either of
##  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## Generic progressive async Merkle tree layer builder.
##
## ``buildLayersAsync`` consumes an ``AsyncIter[?!H]`` one leaf at a time and
## compresses layer pairs in parallel batches on a ``Taskpool``, returning the
## layers of the tree.  Family adapters (``ArchivistTree.buildAsync``,
## ``Poseidon2Tree.buildAsync``) validate leaves, pick the compressor, and
## construct their concrete tree type on top of these layers.
##
## Key semantics are preserved from ``merkleTreeWorker``:
##
## - pairs at level 0 use ``K.KeyBottomLayer``, pairs above use ``K.KeyNone``
## - an odd tail compresses its last node with ``zero`` (node LEFT,
##   zero RIGHT) using ``K.KeyOddAndBottomLayer`` at level 0 and ``K.KeyOdd``
##   above
## - a single node at a non-bottom level is the root and is never compressed
##
## Only complete consecutive pairs are ever compressed eagerly; the odd-tail
## determination is deferred until the stream ends, exactly like the sync
## worker's final pass.  Batch results are appended strictly in seqNum order,
## so the layers do not depend on worker completion order.

{.push raises: [].}

import std/tables
import std/typetraits

import pkg/chronicles
import pkg/chronos
import pkg/taskpools
import pkg/questionable
import pkg/questionable/results

import ../errors
import pkg/iter
import pkg/threadspawn

when defined(archivistAsynctreeTestHooks):
  ## Test-only instrumentation, compiled only into test builds (see
  ## tests/config.nims): batch spawn/completion counters and a worker gate so
  ## the cancellation test can deterministically exercise the drain (hold
  ## workers, cancel, release, assert every spawned worker completed before
  ## cancelAndWait returns).  Never part of production builds.
  import std/atomics

  var testSpawnCount*: Atomic[int]
  var testWorkerCompletions*: Atomic[int]
  var testWorkerGate*: Atomic[bool]
  var testDrainStarted*: Atomic[bool]

  testWorkerGate.store(true) # open by default: workers proceed
  testDrainStarted.store(false)

  proc resetTestHooks*() =
    testSpawnCount.store(0)
    testWorkerCompletions.store(0)
    testWorkerGate.store(true)
    testDrainStarted.store(false)

logScope:
  topics = "archivist asyncbuilder"

const DefaultCompressBatchSize* = 256
  ## Pairs per taskpool task; 256 sha256-pair hashes is ~50us of work,
  ## amortizing the ~10us signal round-trip.

type
  PairJob[H, K] = object
    x, y: H
    key: K

  BatchCtx[H, K, C] = object
    signal: ThreadSignalPtr
    compressor: C # plain value type - worker calls `compress(compressor, ...)` via mixin
    jobs: seq[PairJob[H, K]]
    results: seq[?!H]

  BatchKey = tuple[level: int, seqNum: int]
    # composite: per-level seqNums collide across levels

  PendingBatch[H, K, C] = object
    key: BatchKey
    fut: Future[?!void] # from awaitSpawn
    ctx: SharedPtr[BatchCtx[H, K, C]]

  BuildState[H, K, C] = ref object
    layers: seq[seq[H]]
    consumed: seq[int] # per level: next unpaired node index
    nextSeqNum: seq[int] # per level: next batch seqNum
    completed: Table[BatchKey, seq[H]] # finished, awaiting in-order append
    appendSeqNum: seq[int] # per level: next seqNum to append
    inFlight: seq[PendingBatch[H, K, C]]
    maxOutstanding: int
      # outstanding batch budget (in-flight + completed-not-appended); 2x thread count
    batchSize: int
    tp: Taskpool
    compressor: C
    zero: H
    err: ?ref CatchableError # first worker failure, propagated at drain

proc compressBatchTask[H, K, C](
    ctx: SharedPtr[BatchCtx[H, K, C]]
) {.gcsafe, raises: [].} =
  ## Taskpool worker: compress a batch of pairs, then fire the completion
  ## signal.  Uses the family compressor `C` resolved via `mixin compress` -
  ## not the tree's `CompressFn` closure, which is `noSideEffect` but not
  ## `gcsafe`.
  mixin compress

  when defined(archivistAsynctreeTestHooks):
    # Test gate: spin until released so the cancellation test can hold
    # workers mid-flight and deterministically exercise the drain.
    while not testWorkerGate.load():
      discard

  defer:
    when defined(archivistAsynctreeTestHooks):
      discard testWorkerCompletions.fetchAdd(1)

    # fireSync is what releases the driver's wait: a hard error here would
    # hang the driver forever, so it must never be discarded.  Chronicles is
    # thread-safe from taskpool workers (threadvar TLS).
    if err =? ctx[].signal.fireSync().errorOption:
      warn "Failed to fire worker completion signal", error = err

  for i in 0 ..< ctx[].jobs.len:
    ctx[].results[i] =
      compress(ctx[].compressor, ctx[].jobs[i].x, ctx[].jobs[i].y, ctx[].jobs[i].key)

proc ensureLevel[H, K, C](state: BuildState[H, K, C], level: int) =
  ## Grow the per-level bookkeeping arrays up to `level` (inclusive).
  while state.layers.len <= level:
    state.layers.add(newSeq[H]())
    state.consumed.add(0)
    state.nextSeqNum.add(0)
    state.appendSeqNum.add(0)

proc spawnReadyBatches[H, K, C](state: BuildState[H, K, C], level: int): ?!void =
  ## Spawn a worker batch per `batchSize` complete pairs at `level`
  ## that are not yet consumed, up to the outstanding-work budget
  ## (`maxOutstanding`). Enforcing the budget here - not at the call sites -
  ## is what bounds the cascade in `drainCompletedInOrder`, which would
  ## otherwise spawn every newly-ready upper-level batch in one burst after
  ## out-of-order completions drain. The budget counts completed-not-yet-
  ## appended results too, so out-of-order completions cannot accumulate
  ## unboundedly behind a delayed batch.
  ##
  ## NOTE: do not use `withThreadSignal` here - its block-scoped
  ## `defer: signal.close()` runs right after `tp.spawn`, closing the signal
  ## fd while the worker still holds it.  Follow the kvstore multi-spawn
  ## pattern instead: per-batch signal owned by the SharedPtr ctx, closed
  ## after the worker has fired it.
  while state.layers[level].len - state.consumed[level] >= 2 * state.batchSize and
      state.inFlight.len + state.completed.len < state.maxOutstanding:
    let
      signal = ?ThreadSignalPtr.new().mapFailure
      start = state.consumed[level]
      key = (level, state.nextSeqNum[level])

    var ctx = newSharedPtr(
      BatchCtx[H, K, C](
        signal: signal,
        compressor: state.compressor,
        jobs: newSeqOfCap[PairJob[H, K]](state.batchSize),
        results: newSeq[?!H](state.batchSize),
      )
    )

    for i in 0 ..< state.batchSize:
      ctx[].jobs.add(
        PairJob[H, K](
          x: state.layers[level][start + 2 * i],
          y: state.layers[level][start + 2 * i + 1],
          key: if level == 0: K.KeyBottomLayer else: K.KeyNone,
        )
      )

    state.consumed[level] += 2 * state.batchSize
    inc state.nextSeqNum[level]
    let taskFut = signal.wait()
    if taskFut.failed():
      # wait() registration failed (register2/addReader2): awaitSpawn would
      # return immediately without waiting for the worker, so spawning now
      # would let us close the signal while the worker still holds it
      # (use-after-free on fireSync).  Never spawn; close the signal and
      # propagate the error.
      if closeErr =? signal.close().errorOption:
        warn "Failed to close thread signal", error = closeErr

      return failure(taskFut.error())

    state.tp.spawn compressBatchTask(ctx)
    when defined(archivistAsynctreeTestHooks):
      discard testSpawnCount.fetchAdd(1)

    state.inFlight.add(
      PendingBatch[H, K, C](key: key, fut: awaitSpawn(taskFut), ctx: ctx)
    )

  success()

proc drainCompletedInOrder[H, K, C](state: BuildState[H, K, C]): ?!void =
  ## Append finished batches to the layers strictly in seqNum order per
  ## level, spawning any newly-ready batches on the way up.
  var level = 0
  while level < state.layers.len:
    # Recompute the key on every iteration: appendSeqNum advances per
    # append, so a key bound once per level would strand every batch after
    # the first (the inner loop would re-check a key that was just deleted),
    # and a batch spawned by the final drain call would never be awaited.
    while state.completed.hasKey((level, state.appendSeqNum[level])):
      let key = (level, state.appendSeqNum[level])
      let hashes = state.completed.getOrDefault(key)
      state.completed.del(key)
      ensureLevel(state, level + 1)
      state.layers[level + 1].add(hashes)
      inc state.appendSeqNum[level]
      ?spawnReadyBatches(state, level + 1)

    inc level

  success()

proc oneCompletedBatch[H, K, C](
    state: BuildState[H, K, C]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Wait for one in-flight batch to finish, record its results (or the first
  ## error), close its signal, then append everything that is now in order.
  if state.inFlight.len == 0:
    return success()

  var futs = newSeq[Future[?!void]](state.inFlight.len)
  for i in 0 ..< state.inFlight.len:
    futs[i] = state.inFlight[i].fut

  let doneFut = ?catchAsync(await one(futs))

  var idx = -1
  for i in 0 ..< state.inFlight.len:
    if FutureBase(state.inFlight[i].fut) == FutureBase(doneFut):
      idx = i
      break

  if idx < 0:
    return failure "Internal error: completed batch not found"

  let pb = state.inFlight[idx]
  state.inFlight.delete(idx)

  # The worker has fired the signal; close its fd while the ctx is alive.
  if closeErr =? pb.ctx[].signal.close().errorOption:
    warn "Failed to close thread signal", error = closeErr

  if doneFut.cancelled():
    if state.err.isNone:
      let batchErr: ref CatchableError =
        newException(ArchivistError, "Batch task cancelled")
      state.err = some(batchErr)

    return success()

  if doneFut.failed():
    if state.err.isNone:
      state.err = some(doneFut.error())

    return success()

  let readRes = catchAsync(doneFut.read)
  # readRes is Result[?!void, ref CatchableError]: outer error from read
  # raising, inner ?!void from awaitSpawn returning a failure value.
  if outerErr =? readRes.errorOption:
    if state.err.isNone:
      state.err = some(outerErr)

    return success()

  if innerRes =? readRes:
    if err =? innerRes.errorOption:
      if state.err.isNone:
        state.err = some(err)
      return success()
  else:
    return success()

  var
    hashes = newSeq[H](pb.ctx[].results.len)
    allOk = true

  for i in 0 ..< pb.ctx[].results.len:
    if r =? pb.ctx[].results[i]:
      hashes[i] = r
    else:
      allOk = false
      if e =? pb.ctx[].results[i].errorOption:
        if state.err.isNone:
          state.err = some(e)
      break

  if allOk:
    state.completed[pb.key] = hashes

  ?drainCompletedInOrder(state)
  success()

proc flushTails[H, K, C](state: BuildState[H, K, C]): ?!void =
  ## Bottom-up final pass after the stream ends: finish unpaired pairs and
  ## compress odd tails, mirroring `merkleTreeWorker` exactly.
  mixin compress

  var level = 0
  while level < state.layers.len and state.layers[level].len > 0:
    # A single node at a non-bottom level is the root - pass it through
    # untouched (merkleTreeWorker short-circuits before any compression).
    if state.layers[level].len == 1 and level > 0:
      break

    # Finish any complete pairs not yet consumed (at most one partial batch).
    if state.layers[level].len - state.consumed[level] >= 2:
      var i = state.consumed[level]
      while i + 1 < state.layers[level].len:
        let key = if level == 0: K.KeyBottomLayer else: K.KeyNone
        let hash =
          ?compress(
            state.compressor, state.layers[level][i], state.layers[level][i + 1], key
          )
        ensureLevel(state, level + 1)
        state.layers[level + 1].add(hash)
        i += 2
      state.consumed[level] = state.layers[level].len

    # Odd count: the last node compresses with zero, node LEFT.
    if state.layers[level].len mod 2 == 1:
      let key = if level == 0: K.KeyOddAndBottomLayer else: K.KeyOdd
      let hash = ?compress(state.compressor, state.layers[level][^1], state.zero, key)
      ensureLevel(state, level + 1)
      state.layers[level + 1].add(hash)
    inc level

  success()

proc buildLayersAsync*[H, K, C](
    leaves: AsyncIter[?!H],
    tp: Taskpool,
    compressor: C,
    keys: typedesc[K],
    zero: H,
    batchSize: int = DefaultCompressBatchSize,
): Future[?!seq[seq[H]]] {.async: (raises: [CancelledError]).} =
  ## Build the tree layers progressively from ``leaves``, compressing layer
  ## pairs in parallel batches on ``tp``.  The compressor ``C`` is a plain
  ## value type (checked with ``supportsCopyMem``): it is copied into each
  ## batch's shared memory and read by taskpool workers; the family-specific
  ## ``func compress(c: C, x, y: H, key: K): ?!H`` is resolved via ``mixin``
  ## at instantiation.
  ##
  ## ``keys`` is a typedesc for the key representation (e.g. ``ByteTreeKey``,
  ## ``PoseidonKeysEnum``); its enum member names and ordinals are load-
  ## bearing (see ``MerkleTree.reconstructRoot``).
  ##
  ## The iterator is disposed by this proc (via defer); callers must not use
  ## it afterwards.

  static:
    doAssert supportsCopyMem(C),
      "compressor must be a plain value type: it is copied into shared memory and read by taskpool workers"

  if batchSize < 1:
    return failure "Invalid batch size"

  # Dispose the iterator unconditionally - this defer is installed before any
  # fallible call.  Note: disposing a mapped iterator chains to its source,
  # and dispose is idempotent, so an adapter disposing the same source is
  # safe.
  defer:
    if err =? catchAsync(await leaves.dispose()).errorOption:
      warn "Error disposing leaf iterator", err = err.msg

  var state = BuildState[H, K, C](
    layers: @[newSeq[H]()],
    consumed: @[0],
    nextSeqNum: @[0],
    appendSeqNum: @[0],
    completed: initTable[BatchKey, seq[H]](),
    inFlight: @[],
    maxOutstanding: max(tp.numThreads, 1) * 2,
    batchSize: batchSize,
    tp: tp,
    compressor: compressor,
    zero: zero,
  )

  defer:
    # Cancellation-safe drain: awaitSpawn never cancels the underlying
    # signal wait, so allFutures below completes only once every worker has
    # written its results and fired the signal (fireSync is the worker's
    # final act before its proc epilogue).  That ordering - results written
    # and fireSync happened before signal.close() and before the driver reads
    # ctx[].results - is what makes close/read safe.  The SharedPtr refcount
    # already keeps each BatchCtx alive until the worker's own reference
    # drops; the drain does not exist to protect the allocation.
    when defined(archivistAsynctreeTestHooks):
      testDrainStarted.store(true)

    if state.inFlight.len > 0:
      var futs = newSeq[Future[?!void]](state.inFlight.len)
      for i in 0 ..< state.inFlight.len:
        futs[i] = state.inFlight[i].fut

      await noCancel allFutures(futs)

      for pb in state.inFlight:
        if closeErr =? pb.ctx[].signal.close().errorOption:
          warn "Failed to close thread signal", error = closeErr

      state.inFlight.setLen(0)

  while not leaves.finished:
    let leafRes = ?catchAsync(await leaves.next())
    let leaf = ?leafRes
    state.layers[0].add(leaf)
    ?spawnReadyBatches(state, 0)

    # Backpressure: keep at most 2x thread-count batches outstanding; the
    # same budget is enforced inside spawnReadyBatches (counting buffered
    # out-of-order results too) so neither the cascade nor delayed completions
    # can burst past it.
    if state.inFlight.len + state.completed.len >= state.maxOutstanding:
      ?await oneCompletedBatch(state)

  if state.layers[0].len == 0:
    return failure "Empty leaves"

  # Drain the remaining in-flight batches, then flush the tails.
  while state.inFlight.len > 0:
    ?await oneCompletedBatch(state)

  ?drainCompletedInOrder(state)
  ?flushTails(state)
  if err =? state.err:
    return failure(err)

  success state.layers

when defined(archivistAsynctreeTestHooks):
  proc testDrainCompletedInOrder*[H, K, C](
      layers: seq[seq[H]],
      completed: seq[tuple[level, seqNum: int, hashes: seq[H]]],
      batchSize: int,
  ): ?!seq[seq[H]] =
    ## Test-only: seed a BuildState with an out-of-order completed backlog
    ## at level 0 and run exactly one drain pass, returning the resulting
    ## layers.  Regression guard for the stale-key bug: the drain must append
    ## the ENTIRE backlog (every batch after the first used to strand because
    ## the loop key was bound once per level).
    var state = BuildState[H, K, C](
      layers: layers,
      consumed: newSeq[int](layers.len),
      nextSeqNum: newSeq[int](layers.len),
      appendSeqNum: newSeq[int](layers.len),
      completed: initTable[BatchKey, seq[H]](),
      inFlight: @[],
      maxOutstanding: 8,
      batchSize: batchSize,
      tp: default(Taskpool),
      compressor: default(C),
      zero: default(H),
    )
    for item in completed:
      state.completed[(item.level, item.seqNum)] = item.hashes
    ?drainCompletedInOrder(state)
    success state.layers
