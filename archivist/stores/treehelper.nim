## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/sugar
import pkg/chronos
import pkg/chronos/futures
import pkg/metrics
import pkg/questionable
import pkg/questionable/results

import ./blockstore
import ../utils/asynciter
import ../merkletree

proc putSomeProofs*(
    store: BlockStore, tree: ArchivistTree, iter: Iter[int], storeTree: bool = true
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ## Store leaf CID mappings for selected indices.
  ## If storeTree is true (default), also stores tree nodes for on-demand proof computation.
  ## Set storeTree=false if tree was already stored via putTree or putAllProofs.

  without treeCid =? tree.rootCid, err:
    return failure(err)

  # Store tree nodes for on-demand proof computation
  if storeTree:
    ?await store.putTree(treeCid, tree)

  for i in iter:
    if i notin 0 ..< tree.leavesCount:
      return failure(
        "Invalid leaf index " & $i & ", tree with cid " & $treeCid & " has " &
          $tree.leavesCount & " leaves"
      )

    without blkCid =? tree.getLeafCid(i), err:
      return failure(err)

    without proof =? tree.getProof(i), err:
      return failure(err)

    let res = await store.putCidAndProof(treeCid, i, blkCid, proof)

    if err =? res.errorOption:
      return failure(err)

  success()

proc putSomeProofs*(
    store: BlockStore, tree: ArchivistTree, iter: Iter[Natural], storeTree: bool = true
): Future[?!void] {.async: (raises: [CancelledError], raw: true).} =
  store.putSomeProofs(tree, iter.map((i: Natural) => i.ord), storeTree)

proc putAllProofs*(
    store: BlockStore, tree: ArchivistTree
): Future[?!void] {.async: (raises: [CancelledError], raw: true).} =
  ## Store tree nodes and all leaf CID mappings.
  ## Tree is stored once, then leaf mappings are stored for on-demand proof computation.
  store.putSomeProofs(tree, Iter[int].new(0 ..< tree.leavesCount), storeTree = true)
