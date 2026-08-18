## Copyright (c) 2025 Archivist Authors
## Licensed under either of
##  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## Progressive async ArchivistTree builder.
##
## ``buildAsync`` consumes an ``AsyncIter[Cid]`` one leaf at a time and
## compresses layer pairs in parallel batches on a ``Taskpool``, delegating
## the batching machinery to the generic layer builder in ``../asyncbuilder``.
## The returned ``ArchivistTree`` has layers that are byte-identical to the
## synchronous ``ArchivistTree.init`` build, so proofs and root CIDs match
## exactly.
##
## Leaf validation (multihash codec, digest length) lives here, not in the
## generic core: the core sees only validated digests, surfaced as
## failed/successful ``?!`` items.

{.push raises: [].}

import pkg/iter
import pkg/chronicles
import pkg/chronos
import pkg/taskpools
import pkg/questionable
import pkg/questionable/results
import pkg/libp2p/[cid, multicodec, multihash]

import ../../archivisttypes
import ../../errors
import ../../rng
import ../../utils/digest
import ../asyncbuilder

import ./archivist

export asyncbuilder

logScope:
  topics = "archivist asynctree"

type Sha256Compressor* = object
  ## Stateless compressor tag for the sha256 family.  The generic core
  ## copies this value into shared memory and resolves the actual hash via
  ## ``mixin compress`` (the tree's ``CompressFn`` closure is never touched
  ## by worker threads).

func compress*(c: Sha256Compressor, x, y: ByteHash, key: ByteTreeKey): ?!ByteHash =
  compress(x, y, key)

proc buildAsync*(
    _: type ArchivistTree,
    leaves: AsyncIter[Cid],
    tp: Taskpool,
    mcodec: MultiCodec = Sha256HashCodec,
    batchSize: int = DefaultCompressBatchSize,
): Future[?!ArchivistTree] {.async: (raises: [CancelledError]).} =
  ## Build an ``ArchivistTree`` progressively from ``leaves``, compressing
  ## layer pairs in parallel batches on ``tp``.
  ##
  ## The resulting layers are byte-identical to ``ArchivistTree.init`` for the
  ## same leaves; ``getProof``/``verify``/``rootCid`` work unchanged.
  ##
  ## The iterator is disposed by this proc (via defer); callers must not use
  ## it afterwards.

  # Dispose the iterator unconditionally, including on codec-validation
  # errors below - this defer is installed before any fallible call.
  # AsyncIter.dispose is idempotent, and disposing the mapped iterator in the
  # core chains to this same source, so this never runs twice.
  defer:
    if err =? catchAsync(await leaves.dispose()).errorOption:
      warn "Error disposing leaf iterator", err = err.msg

  let
    digestSize = ?mcodec.digestSize.mapFailure
    zero = newSeq[byte](digestSize)

  proc toDigest(cid: Cid): Future[?!ByteHash] {.async.} =
    ## Validating mapper: every leaf must carry the tree's multihash codec
    ## and a digest of exactly the codec's size.
    let cidHash = ?cid.mhash.mapFailure

    # Compare the multihash codec (not cid.mcodec, which is the content
    # codec), mirroring ArchivistTree.init which derives the tree codec from
    # the leaf.
    if cidHash.mcodec != mcodec:
      return failure "Hash codec mismatch"

    let digest = cidHash.digestBytes
    # Per-leaf length validation - intentionally stricter than
    # ArchivistTree.init (which checks only leaves[0]): a mixed-length input
    # would silently build a wrong tree.  This check is byte-hash-specific,
    # so it stays here rather than in the generic core.
    if digest.len != digestSize:
      return failure "Invalid hash length"

    success digest

  let
    # Explicit generics: U does not infer at some instantiation sites
    # (same workaround as mapAsync in erasure.nim).
    digests = map[Cid, ?!ByteHash](leaves, toDigest)
    layers =
      ?await buildLayersAsync(
        digests, tp, Sha256Compressor(), ByteTreeKey, zero, batchSize
      )

  # Same compressor closure shape as ArchivistTree.init, stored on the
  # returned tree for getProof/verify.
  let compressor = proc(
      x, y: seq[byte], key: ByteTreeKey
  ): ?!ByteHash {.noSideEffect.} =
    compress(x, y, key)

  var tree =
    ArchivistTree(mcodec: mcodec, compress: compressor, zero: zero, layers: layers)

  # Sanity: exactly one root node, plus one random self-verify like fromNodes.
  let root = ?tree.root
  let index = Rng.instance.rand(tree.leavesCount - 1)
  let proof = ?tree.getProof(index)
  if not ?proof.verify(tree.leaves[index], root):
    return failure "Unable to verify asynchronously built tree"

  success tree
