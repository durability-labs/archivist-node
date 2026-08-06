import std/atomics
import std/sequtils

import pkg/chronicles
import pkg/chronos
import pkg/taskpools
import pkg/questionable
import pkg/questionable/results
import pkg/libp2p/cid
import pkg/libp2p/multihash
import pkg/libp2p/multicodec

import pkg/archivist/archivisttypes
import pkg/archivist/errors
import pkg/archivist/merkletree
import pkg/archivist/merkletree/archivist/asynctree
import pkg/archivist/utils/asynciter
import pkg/archivist/utils/iter
import pkg/stew/byteutils

import ../../asynctest

import ./generictreetests

proc makeCids(n: int): ?!seq[Cid] =
  ## Distinct 32-byte leaves for a tree of `n` leaves.
  var cids = newSeq[Cid](n)
  for i in 0 ..< n:
    let
      data =
        @[
          byte(i and 0xff),
          byte((i shr 8) and 0xff),
          byte((i shr 16) and 0xff),
          byte((i shr 24) and 0xff),
        ] & newSeq[byte](28)
      mhash = ?MultiHash.digest($Sha256HashCodec, data).mapFailure
      cid = ?Cid.init(CIDv1, BlockCodec, mhash).mapFailure
    cids[i] = cid
  success cids

proc toAsyncIter(cids: seq[Cid]): AsyncIter[Cid] =
  ## Bridge a seq[Cid] to an AsyncIter for buildAsync.
  proc lift(cid: Cid): Future[Cid] {.async.} =
    cid

  mapAsync[Cid, Cid](Iter[Cid].new(cids), lift)

proc syncTreeOf(cids: seq[Cid]): ?!ArchivistTree =
  ArchivistTree.init(cids)

proc layersEqual(a, b: seq[seq[ByteHash]]): bool =
  ## Element-wise layer comparison (the generic tree `==` ignores contents).
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    if a[i] != b[i]:
      return false
  true

proc checkSameRootCid(a, b: ArchivistTree) =
  let
    aRoot = a.rootCid.tryGet
    sRoot = b.rootCid.tryGet
  check aRoot == sRoot

proc checkSameAsSync(asyncTree, syncTree: ArchivistTree) =
  check:
    asyncTree.layers.len == syncTree.layers.len
    layersEqual(asyncTree.layers, syncTree.layers)
  checkSameRootCid(asyncTree, syncTree)

suite "Async progressive ArchivistTree builder":
  var tp: Taskpool

  setup:
    tp = Taskpool.new(numThreads = 4)

  teardown:
    tp.shutdown()

  # NOTE: do not use the umbrella `import pkg/libp2p` here.  Its large type
  # graph combined with the asynctest `setup:` macro (which injects an extra
  # `proc {.async.}` closure into every `runTest`) makes Nim's ORC destructor
  # synthesis for the async `Env` types pathologically slow (>90s, effectively
  # a hang).  Narrowing the libp2p import to `pkg/libp2p/cid` +
  # `pkg/libp2p/multihash` (the only symbols used) avoids it.  This is a known
  # libp2p / asynctest-setup interaction.
  test "layers are byte-identical to sync build for all small sizes":
    let sizes = concat(toSeq(1 .. 520), @[600, 1000, 1023, 1024, 1025, 2000, 4097])
    for n in sizes:
      let
        cids = makeCids(n).tryGet
        syncTree = syncTreeOf(cids).tryGet
        asyncTree = (await ArchivistTree.buildAsync(toAsyncIter(cids), tp)).tryGet
      checkSameAsSync(asyncTree, syncTree)

  test "proofs from the async tree verify against every leaf":
    let
      cids = makeCids(1000).tryGet
      syncTree = syncTreeOf(cids).tryGet
      tree = (await ArchivistTree.buildAsync(toAsyncIter(cids), tp)).tryGet
      root = tree.root.tryGet
      leaves = tree.leaves
    checkSameRootCid(tree, syncTree)
    for i in 0 ..< cids.len:
      let proof = tree.getProof(i).tryGet
      check proof.verify(leaves[i], root).tryGet

  test "builds progressively from a queue-backed iterator":
    let
      cids = makeCids(1000).tryGet
      syncTree = syncTreeOf(cids).tryGet
      queue = newAsyncQueue[tuple[cid: Cid, isLast: bool]](4)

    var
      allCidsQueued = false
      held: ?Cid

    proc genNext(): Future[Cid] {.async.} =
      let item = await queue.popFirst()
      if item.isLast:
        allCidsQueued = true
      item.cid

    proc isFinished(): bool =
      allCidsQueued

    let iter = AsyncIter[Cid].new(genNext = genNext, isFinished = isFinished)
    let treeFut = ArchivistTree.buildAsync(iter, tp)

    # Only a few leaves available (one held back, as in node.store): the
    # builder must still be consuming.
    for i in 0 ..< 4:
      if prev =? held:
        await queue.addLast((prev, false))
      held = some cids[i]
    await sleepAsync(50.millis)
    check not treeFut.finished

    # Feed the rest, holding one back like node.store, then signal EOF by
    # enqueuing the held final cid flagged isLast.  The builder finishes only
    # after consuming that flagged item: no early finish (it cannot see EOF
    # while items remain) and no hang (the final addLast wakes any popFirst
    # blocked on the empty queue).
    for i in 4 ..< cids.len:
      if prev =? held:
        await queue.addLast((prev, false))
      held = some cids[i]

    if finalCid =? held:
      await queue.addLast((finalCid, true))

    let tree = (await treeFut).tryGet
    checkSameAsSync(tree, syncTree)

  test "cancellation surfaces and leaves the pool usable":
    resetTestHooks() # counters 0, gate open
    testWorkerGate.store(false) # hold workers: none can complete
    defer:
      # Never leave taskpool workers spinning on a failed precondition.
      testWorkerGate.store(true)

    let
      cids = makeCids(16384).tryGet
      iter = toAsyncIter(cids)
      treeFut = ArchivistTree.buildAsync(iter, tp)

    # Wait until backpressure has saturated (2x thread-count batches in
    # flight).  The gate guarantees none of them have completed.
    while testSpawnCount.load() < 2 * tp.numThreads:
      await sleepAsync(1.millis)
      check not treeFut.finished

    check testWorkerCompletions.load() < testSpawnCount.load()

    # Start cancellation; the drain (allFinished on the worker signals) blocks
    # on the gated workers.  Wait until the drain has started, assert the
    # cancellation is genuinely stuck on it, then release the workers.
    let cancelFut = treeFut.cancelAndWait()
    while not testDrainStarted.load():
      await sleepAsync(1.millis)
    check not cancelFut.finished
    testWorkerGate.store(true)
    await cancelFut
    check treeFut.cancelled()

    # Every worker that was ever spawned must have written its results and
    # fired its completion signal before cancelAndWait returned: the
    # awaitSpawn/allFinished drain waits on the signal, which the worker's
    # final defer fires after the counter increment.  (The counter marks entry
    # into that defer, not the taskpool epilogue; the remaining epilogue does
    # not touch the signal or the results.)  Workers were held by the gate
    # while the drain was blocked on them, so this fails on a drain that
    # returns early.
    check testWorkerCompletions.load() == testSpawnCount.load()

    # The builder's defer must have run (not an abrupt abort): the iterator is
    # disposed.  The taskpool must still be healthy - a signal closed before
    # its worker fired would leave the pool writing to a closed eventfd.
    check iter.disposed
    let tree = (await ArchivistTree.buildAsync(toAsyncIter(cids), tp)).tryGet
    check tree.leavesCount == cids.len
    checkSameRootCid(tree, syncTreeOf(cids).tryGet)

  test "rejects empty iterator":
    let
      iter = AsyncIter[Cid].empty()
      r = await ArchivistTree.buildAsync(iter, tp)
    check r.isErr

  test "small batch sizes stream through the taskpool":
    ## batchSize 4 makes small inputs spawn and drain real taskpool batches,
    ## exercising the spawn/budget/drain machinery at every size 1..40.
    for n in 1 .. 40:
      let
        cids = makeCids(n).tryGet
        syncTree = syncTreeOf(cids).tryGet
        asyncTree =
          (await ArchivistTree.buildAsync(toAsyncIter(cids), tp, batchSize = 4)).tryGet
      checkSameAsSync(asyncTree, syncTree)

  test "drain appends the full out-of-order backlog in one pass":
    # Deterministic regression guard: drainCompletedInOrder used to re-check
    # a key bound once per level, stranding every batch after the first in
    # an out-of-order completion backlog (a batch spawned by the final drain
    # was then never awaited).  Two completed batches at level 0, both in
    # `completed` before the drain runs: both must append.
    let r = testDrainCompletedInOrder[ByteHash, ByteTreeKey, Sha256Compressor](
      layers = @[newSeq[ByteHash](), newSeq[ByteHash]()],
      completed =
        @[
          (level: 0, seqNum: 1, hashes: @[newSeq[byte](32), newSeq[byte](32)]),
          (level: 0, seqNum: 0, hashes: @[newSeq[byte](32)]),
        ],
      batchSize = 4,
    )
    check r.isOk
    if r.isOk:
      check:
        r.get.len == 2
        r.get[1].len == 3

# Structural equivalence harness (plain unittest2 suites, registered into the
# same test registry as the asynctest suites above): verifies the async
# builder against hand-computed compress trees, exactly like
# testarchivisttree.nim does for the sync builder.
const genericData = [
  "00000000000000000000000000000001".toBytes,
  "00000000000000000000000000000002".toBytes,
  "00000000000000000000000000000003".toBytes,
  "00000000000000000000000000000004".toBytes,
  "00000000000000000000000000000005".toBytes,
  "00000000000000000000000000000006".toBytes,
  "00000000000000000000000000000007".toBytes,
  "00000000000000000000000000000008".toBytes,
  "00000000000000000000000000000009".toBytes, "00000000000000000000000000000010".toBytes,
]

proc toCidIter(digests: seq[seq[byte]]): AsyncIter[Cid] =
  ## Wrap each digest as a Cid whose multihash carries it verbatim
  ## (MultiHash.init, not MultiHash.digest - the digest IS the leaf).
  var cids = newSeq[Cid](digests.len)
  for i, d in digests:
    let
      mhash = MultiHash.init($Sha256HashCodec, d).mapFailure.tryGet
      cid = Cid.init(CIDv1, BlockCodec, mhash).mapFailure.tryGet
    cids[i] = cid
  toAsyncIter(cids)

# One long-lived pool shared by all harness builds.  Per-call
# Taskpool.new/shutdown cycles raced worker teardown (a rare nil-tree
# segfault that predates the drain fix; root cause was the stale-key drain
# bug, not pool churn, but the single pool matches the suite's proven-stable
# pattern anyway and is simply leaked at process exit, which is fine for a
# test).
let harnessTp = Taskpool.new(numThreads = 2)

let
  genericZero: seq[byte] = newSeq[byte](32)
  genericCompress = proc(x, y: seq[byte], key: ByteTreeKey): seq[byte] =
    compress(x, y, key).tryGet
  makeAsyncTree = proc(data: seq[seq[byte]]): ArchivistTree =
    waitFor(ArchivistTree.buildAsync(toCidIter(data), harnessTp, batchSize = 4)).tryGet

testGenericTree(
  "ArchivistTree (async)", @genericData, genericZero, genericCompress, makeAsyncTree
)
