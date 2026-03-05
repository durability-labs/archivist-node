import pkg/chronos
import pkg/kvstore
import pkg/stew/bitseqs
import pkg/archivist/stores
import pkg/archivist/merkletree
import pkg/archivist/blocktype as bt

import ../../helpers

type
  BlockBitState* = enum
    ## Reasons for BitSeq inconsistency between overlay and leaf metadata
    BitSetButLeafDeleted ## Bit is set in BitSeq but leaf is marked deleted
    LeafExistsButBitNotSet ## Leaf exists and not deleted but bit not set in BitSeq
    BitSetButNoLeafMetadata ## Bit is set in BitSeq but no leaf metadata exists
    InvalidKeyFormat ## Key format is invalid

proc createTestBlock*(size: int): bt.Block =
  bt.Block.new('a'.repeat(size).toBytes).tryGet()

proc putBlockWithOverlay*(
    repo: RepoStore, blk: bt.Block
): Future[?!(Cid, Natural)] {.async.} =
  let (_, tree) = makeManifestAndTree(@[blk]).tryGet()
  let treeCid = tree.rootCid.tryGet()
  let proof = tree.getProof(0).tryGet()
  var blocks = BitSeq.init(1)
  blocks.setBit(0)

  (await repo.putOverlay(treeCid = treeCid, status = Completed.some, blocks = blocks)).tryGet()
  (await repo.putBlocks(treeCid, @[(blk, 0.Natural, proof)])).tryGet()
  success((treeCid, 0.Natural))

proc verifyBlockBitState*(
      self: RepoStore, treeCid: Cid
  ): Future[?!seq[(Natural, BlockBitState)]] {.async: (raises: [CancelledError]).} =
    ## Verify that the overlay BitSeq is consistent with leaf metadata.
    ##
    ## Returns a sequence of (index, reason) for each inconsistency found.
    ## An empty sequence means the overlay is consistent.
    ##
    ## Consistency rules:
    ## - If bit i is set in BitSeq, leaf metadata must exist at index i and not be deleted
    ## - If leaf metadata exists at index i and is not deleted, bit i must be set in BitSeq
    ##
    ## Note: This is an expensive operation that queries all leaf metadata.
    ## Use for debugging and testing only.
    ##

    var states: seq[(Natural, BlockBitState)]
    let
      overlayMeta = ?await self.metaDs.get(?overlayKey(treeCid), OverlayMetadata)
      bits = overlayMeta.val.blocks
      iter =
        ?(await query(self.metaDs, Query.init(?blockLeafQueryKey(treeCid)), LeafMetadata))

    var leafIndices: HashSet[Natural]
    for recordFut in iter:
      if record =? ?catch(?(await recordFut)):
        let indexStr = record.key.value
        without idx =? parseInt(indexStr).catch, err:
          states.add((0.Natural, InvalidKeyFormat))
          trace "Invalid leaf metadata key format", key = record.key
          continue
        leafIndices.incl(idx.Natural)

        if record.val.deleted:
          if idx < bits.len and bits[idx]:
            states.add((idx.Natural, BitSetButLeafDeleted))
        else:
          if idx >= bits.len or not bits[idx]:
            states.add((idx.Natural, LeafExistsButBitNotSet))

    for i in 0 ..< bits.len:
      if bits[i] and i notin leafIndices:
        states.add((i.Natural, BitSetButNoLeafMetadata))

    success(states)
