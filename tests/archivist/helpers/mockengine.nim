## Mock BlockExcEngine for testing
## Simulates network retrieval with configurable responses

{.push raises: [].}

import std/tables

import pkg/chronos
import pkg/libp2p/cid
import pkg/questionable
import pkg/questionable/results

import pkg/archivist/blocktype
import pkg/archivist/blockexchange/engine
import pkg/archivist/blockexchange/engine/pendingblocks
import pkg/archivist/logutils

export engine

logScope:
  topics = "archivist mockengine"

type MockBlockExcEngine* = ref object of BlockExcEngine
  ## Mock engine for testing - simulates network retrieval
  mockBlocks*: Table[BlockAddress, Block] ## Blocks to return on request
  requestedAddresses*: seq[BlockAddress] ## Track what was requested
  requestDelay*: Duration ## Delay before returning blocks
  failRequests*: bool ## If true, fail all requests

proc new*(T: type MockBlockExcEngine): MockBlockExcEngine =
  MockBlockExcEngine(
    mockBlocks: initTable[BlockAddress, Block](),
    requestedAddresses: @[],
    requestDelay: 0.milliseconds,
    failRequests: false,
    pendingBlocks: PendingBlocksManager.new(),
  )

proc addMockBlock*(self: MockBlockExcEngine, address: BlockAddress, blk: Block) =
  self.mockBlocks[address] = blk

proc addMockBlock*(self: MockBlockExcEngine, blk: Block) =
  self.mockBlocks[BlockAddress.init(blk.cid)] = blk

method requestBlock*(
    self: MockBlockExcEngine, address: BlockAddress
): Future[?!Block] {.async: (raises: [CancelledError]).} =
  self.requestedAddresses.add(address)

  if self.requestDelay > 0.milliseconds:
    await sleepAsync(self.requestDelay)

  if self.failRequests:
    return failure(newException(CatchableError, "Mock engine configured to fail"))

  if blk =? self.mockBlocks.getOrDefault(address).some:
    if blk.cid != Cid.default:
      return success(blk)

  # Try to find by CID if it's a leaf address
  if address.leaf:
    let cidAddress = BlockAddress.init(address.treeCid)
    if blk =? self.mockBlocks.getOrDefault(cidAddress).some:
      if blk.cid != Cid.default:
        return success(blk)

  return failure(newException(CatchableError, "Block not found in mock"))

method requestBlock*(
    self: MockBlockExcEngine, cid: Cid
): Future[?!Block] {.async: (raw: true, raises: [CancelledError]).} =
  self.requestBlock(BlockAddress.init(cid))

method start*(self: MockBlockExcEngine) {.async: (raises: []).} =
  discard

method stop*(self: MockBlockExcEngine) {.async: (raises: []).} =
  discard
