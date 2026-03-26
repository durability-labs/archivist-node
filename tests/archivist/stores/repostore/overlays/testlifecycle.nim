import std/os
import std/tempfiles

import pkg/questionable
import pkg/questionable/results

import pkg/chronos
import pkg/taskpools
import pkg/stew/bitseqs
import pkg/kvstore
import pkg/kvstore/fsds

import pkg/archivist/stores
import pkg/archivist/stores/repostore/operations
import pkg/archivist/stores/repostore/types
import pkg/archivist/blocktype as bt
import pkg/archivist/clock

import pkg/archivist/merkletree/archivist

import ../../../../asynctest
import ../../../helpers
import ../../../helpers/mockclock
import ../../../examples

import ./helpers

proc testLifecycle*(
    name: string,
    repoDsProvider: KVStoreProvider,
    metaDsProvider: KVStoreProvider,
    before: Before = nil,
    after: After = nil,
) =
  suite name:
    var
      repoDs: KVStore
      metaDs: KVStore
      mockClock: MockClock
      repo: RepoStore

    let now: SecondsSince1970 = 123

    setup:
      if not isNil(before):
        await before()
      repoDs = repoDsProvider()
      metaDs = metaDsProvider()
      mockClock = MockClock.new()
      mockClock.set(now)
      repo = RepoStore.new(repoDs, metaDs, clock = mockClock, quotaMaxBytes =
          2000'nb)

    teardown:
      (await repoDs.close()).tryGet
      (await metaDs.close()).tryGet
      if not isNil(after):
        await after()

    test "Should drop overlay and remove leafs, blocks, and metadata":
      let
        blk = createTestBlock(120)
        (manifest, tree) = makeManifestAndTree(@[blk]).tryGet()
        treeCid = tree.rootCid.tryGet()
        proof = tree.getProof(0).tryGet()

      var blocks = BitSeq.init(1)
      blocks.setBit(0)

      (
        await repo.putOverlay(
          treeCid = treeCid, status = Completed.some, blocks = blocks
        )
      ).tryGet()
      (await repo.putBlocks(treeCid, @[(blk, 0.Natural, proof)])).tryGet()
      let manifestBlk = (await repo.storeManifest(manifest)).tryGet()

      check repo.quotaUsedBytes > 0.NBytes
      check repo.totalBlocks > 0.Natural

      (await repo.dropOverlay(treeCid)).tryGet()

      let
        leafResult = await repo.getLeafMetadata(treeCid, 0.Natural)
        blockResult = await repo.getBlock(blk.cid)
        overlayResult = await repo.getOverlay(treeCid)
        manifestResult = await repo.getBlock(manifestBlk.cid)

      check leafResult.isErr
      check leafResult.error() of BlockNotFoundError
      check blockResult.isErr
      check blockResult.error() of BlockNotFoundError
      check overlayResult.isErr
      check overlayResult.error() of KVStoreKeyNotFound
      check manifestResult.isErr
      check manifestResult.error() of BlockNotFoundError
      check repo.quotaUsedBytes == 0.NBytes
      check repo.totalBlocks == 0.Natural

    test "Should only decrement refcount for shared blocks when one overlay is dropped":
      let
        shared = createTestBlock(121)
        extra1 = createTestBlock(122)
        extra2 = createTestBlock(123)
        (_, tree1) = makeManifestAndTree(@[shared, extra1]).tryGet()
        (_, tree2) = makeManifestAndTree(@[extra2, shared]).tryGet()
        treeCid1 = tree1.rootCid.tryGet()
        treeCid2 = tree2.rootCid.tryGet()
        proof1 = tree1.getProof(0).tryGet()
        proof2 = tree2.getProof(1).tryGet()

      (
        await repo.putOverlay(
          treeCid = treeCid1, status = Completed.some, blocks = BitSeq.init(2)
        )
      ).tryGet()

      (
        await repo.putOverlay(
          treeCid = treeCid2, status = Completed.some, blocks = BitSeq.init(2)
        )
      ).tryGet()

      (await repo.putBlocks(treeCid1, @[(shared, 0.Natural, proof1)])).tryGet()
      (await repo.putBlocks(treeCid2, @[(shared, 1.Natural, proof2)])).tryGet()
      check (await repo.blockRefCount(shared.cid)).tryGet() == 2.Natural

      let
        manifest1 = Manifest.new(
          treeCid = treeCid1,
          blockSize = NBytes(shared.data.len),
          datasetSize = NBytes(shared.data.len + extra1.data.len),
        )

        manifest2 = Manifest.new(
          treeCid = treeCid2,
          blockSize = NBytes(shared.data.len),
          datasetSize = NBytes(extra2.data.len + shared.data.len),
        )

        manifestBlk1 = (await repo.storeManifest(manifest1)).tryGet()
        manifestBlk2 = (await repo.storeManifest(manifest2)).tryGet()

        quotaBeforeDrop = repo.quotaUsedBytes
        blocksBeforeDrop = repo.totalBlocks

      (await repo.dropOverlay(treeCid1)).tryGet()

      check (await repo.blockRefCount(shared.cid)).tryGet() == 1.Natural
      check (await repo.getBlock(shared.cid)).isOk
      check (await repo.getOverlay(treeCid1)).isErr

      check repo.quotaUsedBytes < quotaBeforeDrop
      check repo.totalBlocks < blocksBeforeDrop

    test "Should drop empty overlay metadata":
      let treeCid = Cid.example

      (
        await repo.putOverlay(
          treeCid = treeCid, status = Storing.some, blocks = BitSeq.init(0)
        )
      ).tryGet()

      (await repo.dropOverlay(treeCid)).tryGet()

      let res = await repo.getOverlay(treeCid)
      check res.isErr
      check res.error() of KVStoreKeyNotFound

    test "Should finalize overlay by moving metadata and leaves":
      let
        blk = createTestBlock(124)
        (_, tree) = makeManifestAndTree(@[blk]).tryGet()
        realTreeCid = tree.rootCid.tryGet()
        proof = tree.getProof(0).tryGet()
        tmpCid = (await repo.createTmpOverlay()).tryGet()

      (await repo.putBlocks(tmpCid, @[(blk, 0.Natural, proof)])).tryGet()
      (await repo.finalizeOverlay(tmpCid, realTreeCid)).tryGet()

      let
        realOverlay = (await repo.getOverlay(realTreeCid)).tryGet()
        leaf = (await repo.getLeafMetadata(realTreeCid, 0.Natural)).tryGet()

      check realOverlay.status == Storing
      check realOverlay.blocks[0]
      check leaf.blkCid == blk.cid

    test "Should remove old tmp overlay metadata after finalize":
      let
        blk = createTestBlock(125)
        (_, tree) = makeManifestAndTree(@[blk]).tryGet()
        realTreeCid = tree.rootCid.tryGet()
        proof = tree.getProof(0).tryGet()
        tmpCid = (await repo.createTmpOverlay()).tryGet()

      (await repo.putBlocks(tmpCid, @[(blk, 0.Natural, proof)])).tryGet()
      (await repo.finalizeOverlay(tmpCid, realTreeCid)).tryGet()

      let res = await repo.getOverlay(tmpCid)
      check res.isErr
      check res.error() of KVStoreKeyNotFound

    test "Should provide block and proof under new tree after finalize":
      let
        blk = createTestBlock(126)
        (_, tree) = makeManifestAndTree(@[blk]).tryGet()
        realTreeCid = tree.rootCid.tryGet()
        proof = tree.getProof(0).tryGet()
        tmpCid = (await repo.createTmpOverlay()).tryGet()

      (await repo.putBlocks(tmpCid, @[(blk, 0.Natural, proof)])).tryGet()
      (await repo.finalizeOverlay(tmpCid, realTreeCid)).tryGet()

      let (_, gotBlock, gotProof) =
        (await repo.getBlockAndProof(realTreeCid, 0.Natural)).tryGet()
      check gotBlock.cid == blk.cid
      check gotProof.index == proof.index
      check gotProof.nleaves == proof.nleaves

    test "finalizeOverlay succeeds when destination leaf exists (content-addressed idempotency)":
      let
        blk = createTestBlock(127)
        (_, tree) = makeManifestAndTree(@[blk]).tryGet()
        realTreeCid = tree.rootCid.tryGet()
        proof = tree.getProof(0).tryGet()
        tmpCid = (await repo.createTmpOverlay()).tryGet()

      # Pre-populate destination with the SAME block at same index
      (await repo.putOverlay(realTreeCid, status = Storing.some)).tryGet()
      (await repo.putBlocks(realTreeCid, @[(blk, 0.Natural, proof)])).tryGet()

      # Put same data in tmp overlay
      (await repo.putBlocks(tmpCid, @[(blk, 0.Natural, proof)])).tryGet()

      # Finalize should succeed (idempotent operation)
      let res = await repo.finalizeOverlay(tmpCid, realTreeCid)
      check res.isOk

      # Tmp overlay should be gone (dropped cleanly)
      let tmpMetaRes = await repo.getOverlay(tmpCid)
      check tmpMetaRes.isErr

      # Destination should still have the data
      let realLeaf = (await repo.getLeafMetadata(realTreeCid, 0.Natural)).tryGet()
      check realLeaf.blkCid == blk.cid

    test "finalizeOverlay handles conflict with different data at same index":
      let
        blk = createTestBlock(128)
        existingBlk = createTestBlock(129)
        (_, tree) = makeManifestAndTree(@[blk]).tryGet()
        realTreeCid = tree.rootCid.tryGet()
        proof = tree.getProof(0).tryGet()
        tmpCid = (await repo.createTmpOverlay()).tryGet()

      # Pre-populate destination with a different block at same index
      (await repo.putOverlay(realTreeCid, status = Storing.some)).tryGet()
      let
        (_, existingTree) = makeManifestAndTree(@[existingBlk]).tryGet()
        existingProof = existingTree.getProof(0).tryGet()

      (await repo.putBlocks(realTreeCid, @[(existingBlk, 0.Natural, existingProof)])).tryGet()

      # Put different data in tmp overlay
      (await repo.putBlocks(tmpCid, @[(blk, 0.Natural, proof)])).tryGet()

      # Finalize should succeed (KVConflictError is caught and handled)
      let res = await repo.finalizeOverlay(tmpCid, realTreeCid)
      check res.isOk

      # Tmp overlay should be gone (dropped on conflict)
      let tmpMetaRes = await repo.getOverlay(tmpCid)
      check tmpMetaRes.isErr

      # Destination should be unchanged (original data preserved)
      let realLeaf = (await repo.getLeafMetadata(realTreeCid, 0.Natural)).tryGet()
      check realLeaf.blkCid == existingBlk.cid

    test "finalizeOverlay succeeds when destination metadata exists":
      let
        blk = createTestBlock(129)
        (_, tree) = makeManifestAndTree(@[blk]).tryGet()
        realTreeCid = tree.rootCid.tryGet()
        proof = tree.getProof(0).tryGet()
        tmpCid = (await repo.createTmpOverlay()).tryGet()

      # Create destination with metadata but no leaf data
      (await repo.putOverlay(realTreeCid, status = Completed.some)).tryGet()

      (await repo.putBlocks(tmpCid, @[(blk, 0.Natural, proof)])).tryGet()
      let res = await repo.finalizeOverlay(tmpCid, realTreeCid)

      check res.isOk

    test "BitSeq preserved through finalizeOverlay (temp to real)":
      let
        blk1 = createTestBlock(300)
        blk2 = createTestBlock(301)
        (_, tree) = makeManifestAndTree(@[blk1, blk2]).tryGet()
        realTreeCid = tree.rootCid.tryGet()
        proof1 = tree.getProof(0).tryGet()
        proof2 = tree.getProof(1).tryGet()
      var capturedTmpCid: Cid

      let res = await repo.withTmpOverlay(
        body = proc(
            tmpCid: Cid
        ): Future[?!Cid] {.closure, async: (raises: [CancelledError]).} =
          capturedTmpCid = tmpCid
          ?await repo.putBlocks(
            tmpCid, @[(blk1, 0.Natural, proof1), (blk2, 1.Natural, proof2)]
          )
          success(realTreeCid)
      )

      check res.isOk

      let realMeta = (await repo.getOverlay(realTreeCid)).tryGet()
      check realMeta.blocks.len >= 2
      check realMeta.blocks[0] == true
      check realMeta.blocks[1] == true

      let inconsistencies = (await repo.verifyBlockBitState(realTreeCid)).tryGet()
      check inconsistencies.len == 0

      let tmpMetaRes = await repo.getOverlay(capturedTmpCid)
      check tmpMetaRes.isErr

    test "BitSeq correct after re-insert of deleted block (resurrection)":
      let
        blk = createTestBlock(302)
        (_, tree) = makeManifestAndTree(@[blk]).tryGet()
        treeCid = tree.rootCid.tryGet()
        proof = tree.getProof(0).tryGet()

      (await repo.putOverlay(treeCid, status = Completed.some)).tryGet()

      # Insert
      (await repo.putBlocks(treeCid, @[(blk, 0.Natural, proof)])).tryGet()
      let meta1 = (await repo.getOverlay(treeCid)).tryGet()
      check meta1.blocks[0] == true

      # Delete
      (await repo.delLeafBlockMetadata(treeCid, @[0.Natural])).tryGet()
      let meta2 = (await repo.getOverlay(treeCid)).tryGet()
      check meta2.blocks[0] == false

      # After deletion, overlay status is Deleting - no resurrection allowed
      let meta3 = (await repo.getOverlay(treeCid)).tryGet()
      check meta3.status == Deleting
      check meta3.blocks[0] == false

      # Attempting to re-insert should fail with OverlayDeletingError
      let putResult = await repo.putBlocks(treeCid, @[(blk, 0.Natural, proof)])
      check putResult.isErr
      check putResult.error() of OverlayDeletingError

      let inconsistencies = (await repo.verifyBlockBitState(treeCid)).tryGet()
      check inconsistencies.len == 0

    test "Should clear leaf metadata when block is deleted from dataset":
      let
        dataset = (await makeRandomBlocks(datasetSize = 512, blockSize = 256'nb)).tryGet
        blk = dataset[0]
        (_, tree) = makeManifestAndTree(dataset).tryGet()
        treeCid = tree.rootCid.tryGet()
        proof = tree.getProof(0).tryGet()

      var blocks = BitSeq.init(1)

      (
        await repo.putOverlay(
          treeCid = treeCid, status = Completed.some, blocks = blocks
        )
      ).tryGet()

      (await repo.putBlocks(treeCid, @[(blk, 0.Natural, proof)])).tryGet()

      discard (await repo.getLeafMetadata(treeCid, 0.Natural)).tryGet()

      (await repo.delBlock(treeCid, 0.Natural)).tryGet()

      let err = (await repo.getLeafMetadata(treeCid, 0.Natural)).error()
      check err of BlockNotFoundError

    test "Should fail re-put after delete due to Deleting status":
      let
        dataset = (await makeRandomBlocks(datasetSize = 512, blockSize = 256'nb)).tryGet
        blk = dataset[0]
        (_, tree) = makeManifestAndTree(dataset).tryGet()
        treeCid = tree.rootCid.tryGet()
        proof = tree.getProof(0).tryGet()

      var blocks = BitSeq.init(1)
      blocks.setBit(0)

      (
        await repo.putOverlay(
          treeCid = treeCid, status = Completed.some, blocks = blocks
        )
      ).tryGet()

      (await repo.putBlocks(treeCid, @[(blk, 0.Natural, proof)])).tryGet()

      (await repo.delBlock(treeCid, 0.Natural)).tryGet()

      let putResult = await repo.putBlocks(treeCid, @[(blk, 0.Natural, proof)])
      check putResult.isErr
      check putResult.error() of OverlayDeletingError

      let meta = (await repo.getOverlay(treeCid)).tryGet()
      check meta.status == Deleting

    test "Should create overlay before running body":
      let treeCid = Cid.example
      var statusDuringBody = Failure

      let res = await repo.withOverlay(
        treeCid,
        status = Storing.some,
        body = proc(): Future[?!void] {.closure, async: (raises: [CancelledError]).} =
          let meta = ?await repo.getOverlay(treeCid)
          statusDuringBody = meta.status
          success(),
      )

      check res.isOk
      check statusDuringBody == Storing

      let meta = (await repo.getOverlay(treeCid)).tryGet()
      check meta.status == Completed

    test "Should set completed state on async body success":
      let treeCid = Cid.example

      let res = await repo.withOverlay(
        treeCid,
        status = Storing.some,
        body = proc(): Future[?!void] {.closure, async: (raises: [CancelledError]).} =
          success(),
      )

      check res.isOk

      let meta = (await repo.getOverlay(treeCid)).tryGet()
      check meta.status == Completed

    test "Should set failure state on async body failure":
      let treeCid = Cid.example

      let res = await repo.withOverlay(
        treeCid,
        status = Storing.some,
        body = proc(): Future[?!void] {.closure, async: (raises: [CancelledError]).} =
          failure(newException(ValueError, "body failed")),
      )

      check res.isErr
      check res.error of ValueError

      let meta = (await repo.getOverlay(treeCid)).tryGet()
      check meta.status == Failure

    test "Should preserve typed body result":
      let treeCid = Cid.example

      let res = await repo.withOverlay(
        treeCid,
        status = Storing.some,
        body = proc(): Future[?!int] {.closure, async: (raises: [CancelledError]).} =
          success(42),
      )

      check res.isOk
      check res.get == 42

      let meta = (await repo.getOverlay(treeCid)).tryGet()
      check meta.status == Completed

    test "Should use custom expiry for final overlay metadata":
      let
        treeCid = Cid.example
        customExpiry: SecondsSince1970 = 500

      let res = await repo.withOverlay(
        treeCid,
        expiry = customExpiry,
        body = proc(): Future[?!void] {.closure, async: (raises: [CancelledError]).} =
          success(),
      )

      check res.isOk

      let meta = (await repo.getOverlay(treeCid)).tryGet()
      check meta.status == Completed
      check meta.expiry == customExpiry

    test "Should keep initial status when body is cancelled":
      let treeCid = Cid.example
      var bodyStarted = newFuture[void]("withOverlay.cancel.started")

      let op = repo.withOverlay(
        treeCid,
        status = Repairing.some,
        body = proc(): Future[?!void] {.closure, async: (raises: [CancelledError]).} =
          if not bodyStarted.finished:
            bodyStarted.complete()
          await sleepAsync(10.seconds)
          success(),
      )

      await bodyStarted.wait(500.millis)
      await op.cancelAndWait()

      expect CancelledError:
        discard await op

      let meta = (await repo.getOverlay(treeCid)).tryGet()
      check meta.status == Repairing

    test "Should retain written leaf metadata when body is cancelled":
      let
        blk = createTestBlock(132)
        (_, tree) = makeManifestAndTree(@[blk]).tryGet()
        treeCid = tree.rootCid.tryGet()
        proof = tree.getProof(0).tryGet()
      var writeDone = newFuture[void]("withOverlay.cancel.writeDone")

      let op = repo.withOverlay(
        treeCid,
        status = Storing.some,
        body = proc(): Future[?!void] {.closure, async: (raises: [CancelledError]).} =
          ?await repo.putBlocks(treeCid, @[(blk, 0.Natural, proof)])
          if not writeDone.finished:
            writeDone.complete()
          await sleepAsync(10.seconds)
          success(),
      )

      await writeDone.wait(500.millis)
      await op.cancelAndWait()

      expect CancelledError:
        discard await op

      let
        meta = (await repo.getOverlay(treeCid)).tryGet()
        leaf = (await repo.getLeafMetadata(treeCid, 0.Natural)).tryGet()
      check meta.status == Storing
      check leaf.blkCid == blk.cid

    test "Should create tmp overlay before running body":
      let realTreeCid = Cid.example
      var statusDuringBody = Failure

      let res = await repo.withTmpOverlay(
        body = proc(
            tmpCid: Cid
        ): Future[?!Cid] {.closure, async: (raises: [CancelledError]).} =
          let tmpMeta = ?await repo.getOverlay(tmpCid)
          statusDuringBody = tmpMeta.status
          success(realTreeCid)
      )

      check res.isOk
      check res.get == realTreeCid
      check statusDuringBody == Storing

      let realMeta = (await repo.getOverlay(realTreeCid)).tryGet()
      check realMeta.status == Completed

    test "Should finalize tmp overlay and move leaves to real tree":
      let
        blk = createTestBlock(130)
        (_, tree) = makeManifestAndTree(@[blk]).tryGet()
        realTreeCid = tree.rootCid.tryGet()
        proof = tree.getProof(0).tryGet()
      var capturedTmpCid: Cid

      let res = await repo.withTmpOverlay(
        body = proc(
            tmpCid: Cid
        ): Future[?!Cid] {.closure, async: (raises: [CancelledError]).} =
          capturedTmpCid = tmpCid
          ?await repo.putBlocks(tmpCid, @[(blk, 0.Natural, proof)])
          success(realTreeCid)
      )

      check res.isOk
      check res.get == realTreeCid

      let leaf = (await repo.getLeafMetadata(realTreeCid, 0.Natural)).tryGet()
      check leaf.blkCid == blk.cid

      let tmpMetaRes = await repo.getOverlay(capturedTmpCid)
      check tmpMetaRes.isErr
      check tmpMetaRes.error() of KVStoreKeyNotFound

      let realMeta = (await repo.getOverlay(realTreeCid)).tryGet()
      check realMeta.status == Completed

    test "Should drop tmp overlay metadata on body failure":
      var capturedTmpCid: Cid

      let res = await repo.withTmpOverlay(
        body = proc(
            tmpCid: Cid
        ): Future[?!Cid] {.closure, async: (raises: [CancelledError]).} =
          capturedTmpCid = tmpCid
          Cid.failure("encode failed")
      )

      check res.isErr
      check "encode failed" in res.error.msg

      let tmpMetaRes = await repo.getOverlay(capturedTmpCid)
      check tmpMetaRes.isErr
      check tmpMetaRes.error() of KVStoreKeyNotFound

    test "Should drop tmp overlay and cleanup stored leafs on body failure":
      let
        blk = createTestBlock(131)
        (_, tree) = makeManifestAndTree(@[blk]).tryGet()
        proof = tree.getProof(0).tryGet()
      var capturedTmpCid: Cid

      let res = await repo.withTmpOverlay(
        body = proc(
            tmpCid: Cid
        ): Future[?!Cid] {.closure, async: (raises: [CancelledError]).} =
          capturedTmpCid = tmpCid
          ?await repo.putBlocks(tmpCid, @[(blk, 0.Natural, proof)])
          Cid.failure("encode failed after storing")
      )

      check res.isErr
      check "encode failed after storing" in res.error.msg

      let tmpMetaRes = await repo.getOverlay(capturedTmpCid)
      check tmpMetaRes.isErr
      check tmpMetaRes.error() of KVStoreKeyNotFound

      let tmpLeafRes = await repo.getLeafMetadata(capturedTmpCid, 0.Natural)
      check tmpLeafRes.isErr
      check tmpLeafRes.error() of BlockNotFoundError

      check repo.quotaUsedBytes == 0.NBytes
      check repo.totalBlocks == 0.Natural

    test "Should drop tmp overlay metadata when body is cancelled":
      let realTreeCid = Cid.example
      var
        capturedTmpCid: Cid
        bodyStarted = newFuture[void]("withTmpOverlay.cancel.started")

      let op = repo.withTmpOverlay(
        body = proc(
            tmpCid: Cid
        ): Future[?!Cid] {.closure, async: (raises: [CancelledError]).} =
          capturedTmpCid = tmpCid
          if not bodyStarted.finished:
            bodyStarted.complete()
          await sleepAsync(10.seconds)
          success(realTreeCid)
      )

      await bodyStarted.wait(500.millis)
      await op.cancelAndWait()

      expect CancelledError:
        discard await op

      let tmpMetaRes = await repo.getOverlay(capturedTmpCid)
      check tmpMetaRes.isErr
      check tmpMetaRes.error() of KVStoreKeyNotFound

    test "Should cleanup tmp overlay leaf and block on body cancellation":
      let
        blk = createTestBlock(133)
        (_, tree) = makeManifestAndTree(@[blk]).tryGet()
        proof = tree.getProof(0).tryGet()

      var
        capturedTmpCid: Cid
        writeDone = newFuture[void]("withTmpOverlay.cancel.writeDone")

      let op = repo.withTmpOverlay(
        body = proc(
            tmpCid: Cid
        ): Future[?!Cid] {.closure, async: (raises: [CancelledError]).} =
          capturedTmpCid = tmpCid
          ?await repo.putBlocks(tmpCid, @[(blk, 0.Natural, proof)])
          if not writeDone.finished:
            writeDone.complete()
          await sleepAsync(10.seconds)
          success(tmpCid)
      )

      await writeDone.wait(500.millis)
      await op.cancelAndWait()

      expect CancelledError:
        discard await op

      let tmpMetaRes = await repo.getOverlay(capturedTmpCid)
      check tmpMetaRes.isErr
      check tmpMetaRes.error() of KVStoreKeyNotFound

      let tmpLeafRes = await repo.getLeafMetadata(capturedTmpCid, 0.Natural)
      check tmpLeafRes.isErr
      check tmpLeafRes.error() of BlockNotFoundError

      let blkRes = await repo.getBlock(blk.cid)
      check blkRes.isErr
      check blkRes.error() of BlockNotFoundError

      check repo.quotaUsedBytes == 0.NBytes
      check repo.totalBlocks == 0.Natural

    test "Should delete verifiable manifest when no slot overlays remain":
      var blocks: seq[bt.Block]
      for size in [100, 101, 102, 103]:
        blocks.add(createTestBlock(size))

      let
        (baseManifest, tree) = makeManifestAndTree(blocks).tryGet()
        treeCid = tree.rootCid.tryGet()
        protManifest = Manifest.new(
          manifest = baseManifest,
          treeCid = treeCid,
          datasetSize = NBytes(8 * 103),
          ecK = 2,
          ecM = 2,
        )

      var slotRoots: seq[Cid]
      for _ in 0 ..< 4:
        slotRoots.add(Cid.example)

      let verManifest = Manifest.new(protManifest, Cid.example, slotRoots).tryGet()

      var bits = BitSeq.init(blocks.len)
      for i in 0 ..< blocks.len:
        bits.setBit(i)

      (await repo.putOverlay(treeCid = treeCid, status = Completed.some, blocks = bits)).tryGet()

      var blkProofs: seq[(bt.Block, Natural, ArchivistProof)]
      for i, blk in blocks:
        blkProofs.add((blk, i.Natural, tree.getProof(i).tryGet()))

      (await repo.putBlocks(treeCid, blkProofs)).tryGet()

      let
        protManifestBlk = (await repo.storeManifest(protManifest)).tryGet()
        verManifestBlk = (await repo.storeVerifiableManifest(verManifest)).tryGet()

      # Drop tree overlay: protected manifest deleted, verifiable manifest untouched
      (await repo.dropOverlay(treeCid)).tryGet()

      check (await repo.getBlock(protManifestBlk.cid)).isErr
      check (await repo.getBlock(verManifestBlk.cid)).isOk

      # Drop all slot overlays; last one deletes the verifiable manifest
      for slotRoot in slotRoots:
        (await repo.dropOverlay(slotRoot)).tryGet()

      check (await repo.getBlock(verManifestBlk.cid)).isErr
      check repo.quotaUsedBytes == 0.NBytes
      check repo.totalBlocks == 0.Natural

    test "Should skip verifiable manifest delete when slot overlays still exist":
      var blocks: seq[bt.Block]
      for size in [100, 101, 102, 103]:
        blocks.add(createTestBlock(size))

      let
        (baseManifest, tree) = makeManifestAndTree(blocks).tryGet()
        treeCid = tree.rootCid.tryGet()
        protManifest = Manifest.new(
          manifest = baseManifest,
          treeCid = treeCid,
          datasetSize = NBytes(8 * 103),
          ecK = 2,
          ecM = 2,
        )

      var slotRoots: seq[Cid]
      for _ in 0 ..< 4:
        slotRoots.add(Cid.example)

      let verManifest = Manifest.new(protManifest, Cid.example, slotRoots).tryGet()

      var bits = BitSeq.init(blocks.len)
      for i in 0 ..< blocks.len:
        bits.setBit(i)

      (await repo.putOverlay(treeCid = treeCid, status = Completed.some, blocks = bits)).tryGet()

      var blkProofs: seq[(bt.Block, Natural, ArchivistProof)]
      for i, blk in blocks:
        blkProofs.add((blk, i.Natural, tree.getProof(i).tryGet()))

      (await repo.putBlocks(treeCid, blkProofs)).tryGet()

      let
        protManifestBlk = (await repo.storeManifest(protManifest)).tryGet()
        verManifestBlk = (await repo.storeVerifiableManifest(verManifest)).tryGet()
        verManifestBytes = verManifestBlk.data.len.NBytes

      # Drop tree overlay: data blocks + protected manifest gone
      (await repo.dropOverlay(treeCid)).tryGet()

      for blk in blocks:
        check (await repo.getBlock(blk.cid)).isErr

      check (await repo.getBlock(protManifestBlk.cid)).isErr
      check (await repo.getBlock(verManifestBlk.cid)).isOk
      check repo.quotaUsedBytes == verManifestBytes
      check repo.totalBlocks == 1.Natural

      # Drop all but the last slot overlay; verifiable manifest persists
      for i in 0 ..< slotRoots.len - 1:
        (await repo.dropOverlay(slotRoots[i])).tryGet()

      check (await repo.getBlock(verManifestBlk.cid)).isOk

      # Drop last slot overlay; verifiable manifest is now deleted
      (await repo.dropOverlay(slotRoots[^1])).tryGet()

      check (await repo.getBlock(verManifestBlk.cid)).isErr
      check repo.quotaUsedBytes == 0.NBytes
      check repo.totalBlocks == 0.Natural

    test "Should handle protected and verifiable manifests independently":
      var blocks: seq[bt.Block]
      for size in [100, 101, 102, 103]:
        blocks.add(createTestBlock(size))

      let
        (baseManifest, tree) = makeManifestAndTree(blocks).tryGet()
        treeCid = tree.rootCid.tryGet()
        protManifest = Manifest.new(
          manifest = baseManifest,
          treeCid = treeCid,
          datasetSize = NBytes(8 * 103),
          ecK = 2,
          ecM = 2,
        )

      var slotRoots: seq[Cid]
      for _ in 0 ..< 4:
        slotRoots.add(Cid.example)

      let verManifest = Manifest.new(protManifest, Cid.example, slotRoots).tryGet()

      var bits = BitSeq.init(blocks.len)
      for i in 0 ..< blocks.len:
        bits.setBit(i)

      (await repo.putOverlay(treeCid = treeCid, status = Completed.some, blocks = bits)).tryGet()

      var blkProofs: seq[(bt.Block, Natural, ArchivistProof)]
      for i, blk in blocks:
        blkProofs.add((blk, i.Natural, tree.getProof(i).tryGet()))

      (await repo.putBlocks(treeCid, blkProofs)).tryGet()

      # Step 1: store both manifests
      let
        protManifestBlk = (await repo.storeManifest(protManifest)).tryGet()
        verManifestBlk = (await repo.storeVerifiableManifest(verManifest)).tryGet()
        dataBytes = NBytes(100 + 101 + 102 + 103)
        protManifestBytes = protManifestBlk.data.len.NBytes
        verManifestBytes = verManifestBlk.data.len.NBytes

      # All blocks + both manifests should be on disk
      for blk in blocks:
        check (await repo.getBlock(blk.cid)).isOk
      check (await repo.getBlock(protManifestBlk.cid)).isOk
      check (await repo.getBlock(verManifestBlk.cid)).isOk
      check repo.quotaUsedBytes == dataBytes + protManifestBytes + verManifestBytes
      check repo.totalBlocks == (blocks.len + 2).Natural

      # Step 2: drop tree overlay - data blocks and protected manifest are cleaned up
      (await repo.dropOverlay(treeCid)).tryGet()

      for blk in blocks:
        check (await repo.getBlock(blk.cid)).isErr

      check (await repo.getBlock(protManifestBlk.cid)).isErr

      # Verifiable manifest survives (slot overlays still exist)
      check (await repo.getBlock(verManifestBlk.cid)).isOk
      check repo.quotaUsedBytes == verManifestBytes
      check repo.totalBlocks == 1.Natural

      # Step 3: drop all slot overlays - verifiable manifest is cleaned up
      for slotRoot in slotRoots:
        (await repo.dropOverlay(slotRoot)).tryGet()

      check (await repo.getBlock(verManifestBlk.cid)).isErr
      check repo.quotaUsedBytes == 0.NBytes
      check repo.totalBlocks == 0.Natural

    test "Should track manifest refCount across slot overlays":
      var blocks: seq[bt.Block]
      for size in [100, 101, 102, 103]:
        blocks.add(createTestBlock(size))

      let
        (baseManifest, tree) = makeManifestAndTree(blocks).tryGet()
        treeCid = tree.rootCid.tryGet()
        protManifest = Manifest.new(
          manifest = baseManifest,
          treeCid = treeCid,
          datasetSize = NBytes(8 * 103),
          ecK = 2,
          ecM = 2,
        )

      var slotRoots: seq[Cid]
      for _ in 0 ..< 4:
        slotRoots.add(Cid.example)

      let verManifest = Manifest.new(protManifest, Cid.example, slotRoots).tryGet()

      # Store verifiable manifest - should create 4 slot overlays with refCount=4
      let verManifestBlk = (await repo.storeVerifiableManifest(verManifest)).tryGet()

      check (await repo.blockRefCount(verManifestBlk.cid)).tryGet() == 4.Natural

      # Drop one slot overlay - refCount should be 3
      (await repo.dropOverlay(slotRoots[0])).tryGet()
      check (await repo.blockRefCount(verManifestBlk.cid)).tryGet() == 3.Natural

      # Drop two more - refCount should be 1
      (await repo.dropOverlay(slotRoots[1])).tryGet()
      (await repo.dropOverlay(slotRoots[2])).tryGet()
      check (await repo.blockRefCount(verManifestBlk.cid)).tryGet() == 1.Natural

      # Drop last - manifest block should be deleted (refCount 0)
      (await repo.dropOverlay(slotRoots[3])).tryGet()
      check (await repo.getBlock(verManifestBlk.cid)).isErr
      check repo.quotaUsedBytes == 0.NBytes
      check repo.totalBlocks == 0.Natural

    test "Should cleanup manifest exactly once when slot overlays are dropped concurrently":
      var blocks: seq[bt.Block]
      for size in [100, 101, 102, 103]:
        blocks.add(createTestBlock(size))

      let
        (baseManifest, tree) = makeManifestAndTree(blocks).tryGet()
        treeCid = tree.rootCid.tryGet()
        protManifest = Manifest.new(
          manifest = baseManifest,
          treeCid = treeCid,
          datasetSize = NBytes(8 * 103),
          ecK = 2,
          ecM = 2,
        )

      var slotRoots: seq[Cid]
      for _ in 0 ..< 4:
        slotRoots.add(Cid.example)

      let verManifest = Manifest.new(protManifest, Cid.example, slotRoots).tryGet()
      let verManifestBlk = (await repo.storeVerifiableManifest(verManifest)).tryGet()

      check (await repo.blockRefCount(verManifestBlk.cid)).tryGet() == 4.Natural

      # Drop all slot overlays concurrently - the original race condition scenario
      var dropFutures: seq[Future[?!void]]
      for slotRoot in slotRoots:
        dropFutures.add(repo.dropOverlay(slotRoot))

      await allFutures(dropFutures)

      for fut in dropFutures:
        check fut.value.isOk

      # Manifest should be fully cleaned up
      check (await repo.getBlock(verManifestBlk.cid)).isErr
      check repo.quotaUsedBytes == 0.NBytes
      check repo.totalBlocks == 0.Natural

    test "Should attach only one slot overlay when slotIdx is provided":
      var blocks: seq[bt.Block]
      for size in [100, 101, 102, 103]:
        blocks.add(createTestBlock(size))

      let
        (baseManifest, tree) = makeManifestAndTree(blocks).tryGet()
        treeCid = tree.rootCid.tryGet()
        protManifest = Manifest.new(
          manifest = baseManifest,
          treeCid = treeCid,
          datasetSize = NBytes(8 * 103),
          ecK = 2,
          ecM = 2,
        )

      var slotRoots: seq[Cid]
      for _ in 0 ..< 4:
        slotRoots.add(Cid.example)

      let verManifest = Manifest.new(protManifest, Cid.example, slotRoots).tryGet()

      # Store with slotIdx=1 - only slot 1 overlay should be created
      let verManifestBlk = (
        await repo.storeVerifiableManifest(verManifest, slotIdx = 1.Natural.some)
      ).tryGet()

      # Only one overlay created, so refCount should be 1
      check (await repo.blockRefCount(verManifestBlk.cid)).tryGet() == 1.Natural

      # Only slot 1 overlay should have manifestCid
      let overlay1 = (await repo.getOverlay(slotRoots[1])).tryGet()
      check overlay1.manifestCid == verManifestBlk.cid.some

      # Other slot overlays should not exist
      for i in [0, 2, 3]:
        check (await repo.getOverlay(slotRoots[i])).isErr

      # Dropping the single slot overlay should delete the manifest
      (await repo.dropOverlay(slotRoots[1])).tryGet()
      check (await repo.getBlock(verManifestBlk.cid)).isErr

    test "Should reject slotIdx for non-verifiable manifest":
      let
        blk = createTestBlock(100)
        (manifest, _) = makeManifestAndTree(@[blk]).tryGet()

      let result =
        await repo.storeVerifiableManifest(manifest, slotIdx = 0.Natural.some)
      check result.isErr

    test "Should fire onBlockStored callback when storing manifest":
      let
        blk = createTestBlock(100)
        (manifest, tree) = makeManifestAndTree(@[blk]).tryGet()
        treeCid = tree.rootCid.tryGet()

      var callbackCid: ?Cid
      repo.onBlockStored = (
        proc(cid: Cid): Future[void] {.async: (raises: []).} =
          callbackCid = cid.some
      ).some

      (await repo.putOverlay(treeCid = treeCid, status = Completed.some)).tryGet()
      let manifestBlk = (await repo.storeManifest(manifest)).tryGet()

      check callbackCid.isSome
      check callbackCid == manifestBlk.cid.some

    test "Should handle idempotent storeManifest without double-counting refCount":
      let
        blk = createTestBlock(100)
        (manifest, tree) = makeManifestAndTree(@[blk]).tryGet()
        treeCid = tree.rootCid.tryGet()

      (await repo.putOverlay(treeCid = treeCid, status = Completed.some)).tryGet()

      # Store manifest first time
      let manifestBlk1 = (await repo.storeManifest(manifest)).tryGet()
      check (await repo.blockRefCount(manifestBlk1.cid)).tryGet() == 1.Natural

      let quotaAfterFirst = repo.quotaUsedBytes

      # Store same manifest again - overlay already has manifestCid,
      # so overlaysToUpdate should be empty and refCount unchanged
      let manifestBlk2 = (await repo.storeManifest(manifest)).tryGet()
      check manifestBlk1.cid == manifestBlk2.cid
      check (await repo.blockRefCount(manifestBlk1.cid)).tryGet() == 1.Natural

      # Quota should not increase (block already on disk)
      check repo.quotaUsedBytes == quotaAfterFirst

    test "Should succeed dropManifest on overlay without manifestCid":
      let treeCid = Cid.example

      (await repo.putOverlay(treeCid = treeCid, status = Completed.some)).tryGet()

      # dropManifest on overlay with no manifestCid should be a no-op
      (await repo.dropManifest(treeCid)).tryGet()

      # Overlay should still exist and be unchanged
      let overlay = (await repo.getOverlay(treeCid)).tryGet()
      check overlay.status == Completed
      check overlay.manifestCid.isNone

proc runFsSqliteTests() =
  let repoDir = createTempDir("archivist-", "-repostore")

  testLifecycle(
    "Overlay lifecycle FS+SQLite backend",
    repoDsProvider = proc(): KVStore =
      if not dirExists(repoDir):
        createDir(repoDir)
      let tp = Taskpool.new()
      FSKVStore.new(repoDir, tp, depth = 5).tryGet(),
    metaDsProvider = proc(): KVStore =
      let tp = Taskpool.new()
      SQLiteKVStore.new(SqliteMemory, tp).tryGet(),
    after = proc(): Future[void] {.async.} =
      os.removeDir(repoDir),
  )

runFsSqliteTests()
