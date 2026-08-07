import std/sequtils

import pkg/chronicles
import pkg/chronos
import pkg/taskpools
import pkg/poseidon2
import pkg/poseidon2/io
import pkg/questionable
import pkg/questionable/results
import pkg/stew/byteutils

import pkg/archivist/merkletree
import pkg/archivist/merkletree/asyncposeidon2
import pkg/iter

import ../../asynctest

import ./generictreetests

proc makeLeaves(n: int): seq[Poseidon2Hash] =
  ## n distinct field elements: bytes 0..2 encode the index in little-endian.
  ## Values stay far below the BN254 prime, so fromBytes is injective.
  var leaves = newSeq[Poseidon2Hash](n)
  for i in 0 ..< n:
    var bytes: array[31, byte]
    bytes[0] = byte(i and 0xff)
    bytes[1] = byte((i shr 8) and 0xff)
    bytes[2] = byte((i shr 16) and 0xff)
  leaves

proc toAsyncIter(leaves: seq[Poseidon2Hash]): AsyncIter[Poseidon2Hash] =
  ## Bridge a seq[Poseidon2Hash] to an AsyncIter for buildAsync.
  proc lift(h: Poseidon2Hash): Future[Poseidon2Hash] {.async.} =
    h

  mapAsync[Poseidon2Hash, Poseidon2Hash](Iter[Poseidon2Hash].new(leaves), lift)

proc layersEqual(a, b: seq[seq[Poseidon2Hash]]): bool =
  ## Element-wise layer comparison (the generic tree `==` ignores contents).
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    if a[i] != b[i]:
      return false
  true

proc checkSameAsSync(asyncTree, syncTree: Poseidon2Tree) =
  check:
    asyncTree.layers.len == syncTree.layers.len
    layersEqual(asyncTree.layers, syncTree.layers)
    bool(asyncTree.root.tryGet == syncTree.root.tryGet)

suite "Async progressive Poseidon2Tree builder":
  var tp: Taskpool

  setup:
    tp = Taskpool.new(numThreads = 4)

  teardown:
    tp.shutdown()

  # NOTE: do not import `./helpers` or `../../helpers` here: helpers.nim
  # imports the umbrella `pkg/libp2p`, which combined with the asynctest
  # `setup:` macro makes Nim's ORC destructor synthesis pathologically slow
  # (see the identical note in testasynctree.nim).  Compare layers directly.
  test "layers are identical to sync build for all small sizes":
    ## Sizes >= 512 are what actually spawn batches at the default batchSize
    ## (a batch needs 2 * batchSize unconsumed nodes).
    let sizes = concat(toSeq(1 .. 40), @[511, 512, 513, 1023, 1024, 1025, 2048, 4097])
    for n in sizes:
      let
        leaves = makeLeaves(n)
        syncTree = Poseidon2Tree.init(leaves).tryGet
        asyncTree = (await Poseidon2Tree.buildAsync(toAsyncIter(leaves), tp)).tryGet
      checkSameAsSync(asyncTree, syncTree)

  test "small batch sizes stream through the taskpool":
    ## batchSize 4 makes small inputs spawn and drain real taskpool batches,
    ## exercising the spawn/budget/drain machinery at every size 1..40.
    for n in 1 .. 40:
      let
        leaves = makeLeaves(n)
        syncTree = Poseidon2Tree.init(leaves).tryGet
        asyncTree = (
          await Poseidon2Tree.buildAsync(toAsyncIter(leaves), tp, batchSize = 4)
        ).tryGet
      checkSameAsSync(asyncTree, syncTree)

  test "proofs from the async tree verify against every leaf":
    let
      leaves = makeLeaves(600)
      syncTree = Poseidon2Tree.init(leaves).tryGet
      tree = (await Poseidon2Tree.buildAsync(toAsyncIter(leaves), tp)).tryGet
      root = tree.root.tryGet
    check bool(root == syncTree.root.tryGet)
    for i in 0 ..< leaves.len:
      let proof = tree.getProof(i).tryGet
      check proof.verify(tree.leaves[i], root).tryGet

  test "rejects empty iterator":
    let
      iter = AsyncIter[Poseidon2Hash].empty()
      r = await Poseidon2Tree.buildAsync(iter, tp)
    check r.isErr

# Structural equivalence harness (plain unittest2 suites, registered into the
# same test registry as the asynctest suites above): verifies the async
# builder against hand-computed compress trees, exactly like
# testposeidon2tree.nim does for the sync builder.
const data = [
  "0000000000000000000000000000001".toBytes,
  "0000000000000000000000000000002".toBytes,
  "0000000000000000000000000000003".toBytes,
  "0000000000000000000000000000004".toBytes,
  "0000000000000000000000000000005".toBytes,
  "0000000000000000000000000000006".toBytes,
  "0000000000000000000000000000007".toBytes,
  "0000000000000000000000000000008".toBytes,
  "0000000000000000000000000000009".toBytes,
    # note one less to account for padding of field elements
]

# One long-lived pool shared by all harness builds.  Per-call
# Taskpool.new/shutdown cycles raced worker teardown (a rare nil-tree
# segfault that predates the drain fix; root cause was the stale-key drain
# bug, not pool churn, but the single pool matches the suite's proven-stable
# pattern anyway and is simply leaked at process exit, which is fine for a
# test).
let harnessTp = Taskpool.new(numThreads = 2)

let
  compressor = proc(
      x, y: Poseidon2Hash, key: PoseidonKeysEnum
  ): Poseidon2Hash {.noSideEffect.} =
    compress(x, y, key.toKey)

  makeAsyncTree = proc(data: seq[Poseidon2Hash]): Poseidon2Tree =
    waitFor(Poseidon2Tree.buildAsync(toAsyncIter(data), harnessTp, batchSize = 4)).tryGet

testGenericTree(
  "Poseidon2Tree (async)",
  toSeq(data.concat().elements(Poseidon2Hash)),
  zero,
  compressor,
  makeAsyncTree,
)
