## Copyright (c) 2025 Archivist Authors
## Licensed under either of
##  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## Progressive async Poseidon2Tree builder.
##
## ``buildAsync`` consumes an ``AsyncIter[Poseidon2Hash]`` one leaf at a time
## and compresses layer pairs in parallel batches on a ``Taskpool``,
## delegating the batching machinery to the generic layer builder in
## ``../asyncbuilder``.  The returned ``Poseidon2Tree`` has layers that are
## identical to the synchronous ``Poseidon2Tree.init`` build, so proofs
## verify exactly.
##
## This module exists separately from ``poseidon2.nim`` so the sync-only
## consumers of that module (slots, proofs) do not inherit chronos/taskpools;
## adapters import it explicitly when they need the async builder.

{.push raises: [].}

import pkg/iter
import pkg/chronos
import pkg/taskpools
import pkg/chronicles
import pkg/questionable
import pkg/questionable/results

import ../errors
import ../rng

import ./asyncbuilder
import ./poseidon2

export asyncbuilder, poseidon2

logScope:
  topics = "archivist asyncposeidon2"

type Poseidon2Compressor* = object
  ## Stateless compressor tag for the Poseidon2 family.  The generic core
  ## copies this value into shared memory and resolves the actual hash via
  ## ``mixin compress`` (the tree's ``CompressFn`` closure is never touched
  ## by worker threads).

func compress*(
    c: Poseidon2Compressor, x, y: Poseidon2Hash, key: PoseidonKeysEnum
): ?!Poseidon2Hash =
  ## Compress two field elements with the poseidon2 permutation, keyed by the
  ## field-element representation of the domain-separation enum (`toKey`).
  success compress(x, y, key.toKey)

proc buildAsync*(
    _: type Poseidon2Tree,
    leaves: AsyncIter[Poseidon2Hash],
    tp: Taskpool,
    batchSize: int = DefaultCompressBatchSize,
): Future[?!Poseidon2Tree] {.async: (raises: [CancelledError]).} =
  ## Build a ``Poseidon2Tree`` progressively from ``leaves``, compressing
  ## layer pairs in parallel batches on ``tp``.
  ##
  ## The resulting layers are identical to ``Poseidon2Tree.init`` for the
  ## same leaves; ``getProof``/``verify`` work unchanged.
  ##
  ## The iterator is disposed by this proc (via defer); callers must not use
  ## it afterwards.

  # Dispose the iterator unconditionally - this defer is installed before any
  # fallible call.  AsyncIter.dispose is idempotent, and disposing the mapped
  # iterator in the core chains to this same source, so this never runs
  # twice.
  defer:
    if err =? catchAsync(await leaves.dispose()).errorOption:
      warn "Error disposing leaf iterator", err = err.msg

  proc lift(h: Poseidon2Hash): Future[?!Poseidon2Hash] {.async.} =
    ## Identity mapper: field elements are fixed-size and self-describing, so
    ## there is nothing to validate at the adapter boundary.
    success h

  let
    # Explicit generics: U does not infer at some instantiation sites
    # (same workaround as mapAsync in erasure.nim).
    items = map[Poseidon2Hash, ?!Poseidon2Hash](leaves, lift)
    layers =
      ?await buildLayersAsync(
        items, tp, Poseidon2Compressor(), PoseidonKeysEnum, Poseidon2Zero, batchSize
      )

  # Same compressor closure shape as Poseidon2Tree.init, stored on the
  # returned tree for getProof/verify.
  let compressor = proc(
      x, y: Poseidon2Hash, key: PoseidonKeysEnum
  ): ?!Poseidon2Hash {.noSideEffect.} =
    success compress(x, y, key.toKey)

  var tree = Poseidon2Tree(compress: compressor, zero: Poseidon2Zero, layers: layers)

  # Sanity: exactly one root node, plus one random self-verify like fromNodes.
  let root = ?tree.root
  let index = Rng.instance.rand(tree.leavesCount - 1)
  let proof = ?tree.getProof(index)
  if not ?proof.verify(tree.leaves[index], root):
    return failure "Unable to verify asynchronously built tree"

  success tree
