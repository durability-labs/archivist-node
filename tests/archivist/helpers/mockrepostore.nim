## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils
import pkg/chronos
import pkg/libp2p
import pkg/questionable
import pkg/questionable/results

import pkg/archivist/stores/repostore
import pkg/archivist/utils/asynciter
import pkg/archivist/utils/safeasynciter

type MockRepoStore* = ref object of RepoStore
  delBlockCids*: seq[Cid]
  getBeMaxNumber*: int
  getBeOffset*: int

  testBlockExpirations*: seq[BlockExpiration]

method delBlock*(
    self: MockRepoStore, cid: Cid
): Future[?!void] {.
    async: (raises: [CancelledError]), deprecated: "Use delBlock(treeCid, idx)"
.} =
  self.delBlockCids.add(cid)
  self.testBlockExpirations = self.testBlockExpirations.filterIt(it.cid != cid)
  return success()
