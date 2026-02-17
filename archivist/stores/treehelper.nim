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

import pkg/libp2p/cid

import ./blockstore
import ../utils/asynciter
import ../merkletree

proc putSomeProofs*(
    store: BlockStore, tree: ArchivistTree, iter: Iter[int]
): Future[?!void] {.async: (raises: [CancelledError]).} =
  let treeCid = ?tree.rootCid

  var items: seq[(Natural, Cid, ArchivistProof)]
  for i in iter:
    if i notin 0 ..< tree.leavesCount:
      return failure(
        "Invalid leaf index " & $i & ", tree with cid " & $treeCid & " has " &
          $tree.leavesCount & " leaves"
      )

    let
      blkCid = ?tree.getLeafCid(i)
      proof = ?tree.getProof(i)

    items.add((i.Natural, blkCid, proof))

  ?await store.putCidsAndProofs(treeCid, items)
  success()

proc putSomeProofs*(
    store: BlockStore, tree: ArchivistTree, iter: Iter[Natural]
): Future[?!void] {.async: (raises: [CancelledError], raw: true).} =
  store.putSomeProofs(tree, iter.map((i: Natural) => i.ord))

proc putAllProofs*(
    store: BlockStore, tree: ArchivistTree
): Future[?!void] {.async: (raises: [CancelledError], raw: true).} =
  store.putSomeProofs(tree, Iter[int].new(0 ..< tree.leavesCount))
