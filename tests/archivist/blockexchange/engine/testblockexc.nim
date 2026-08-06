import std/sequtils
import std/algorithm

import pkg/chronos
import pkg/taskpools
import pkg/stew/byteutils

import pkg/archivist/stores
import pkg/archivist/blockexchange
import pkg/archivist/chunker
import pkg/archivist/discovery
import pkg/archivist/blocktype as bt
import pkg/archivist/manifest
import pkg/archivist/errors

import ../../../asynctest
import ../../helpers

import ../../helpers/nodeutils

asyncchecksuite "NetworkStore engine - 2 nodes":
  var
    nodeCmps1, nodeCmps2: NodesComponents
    peerCtx1, peerCtx2: BlockExcPeerCtx
    blocks1, blocks2: seq[bt.Block]
    manifest1, manifest2: Manifest
    pendingBlocks1, pendingBlocks2: seq[BlockHandle]

  setup:
    blocks1 = (await makeRandomBlocks(datasetSize = 2048, blockSize = 256'nb)).tryGet
    blocks2 = (await makeRandomBlocks(datasetSize = 2048, blockSize = 256'nb)).tryGet
    nodeCmps1 = (await generateNodes(1)).components[0]
    nodeCmps2 = (await generateNodes(1)).components[0]

    # Store blocks as trees on each node
    manifest1 = (await storeDataGetManifest(nodeCmps1.localStore, blocks1)).tryGet()
    manifest2 = (await storeDataGetManifest(nodeCmps2.localStore, blocks2)).tryGet()

    # Attach manifests to their local overlays
    discard (await nodeCmps1.localStore.storeManifest(manifest1)).tryGet()
    discard (await nodeCmps2.localStore.storeManifest(manifest2)).tryGet()

    # Pre-create overlays on the opposite nodes so they can receive leaf blocks
    discard (await nodeCmps1.localStore.storeManifest(manifest2)).tryGet()
    discard (await nodeCmps2.localStore.storeManifest(manifest1)).tryGet()

    await allFuturesThrowing(
      nodeCmps1.switch.start(),
      nodeCmps1.blockDiscovery.start(),
      nodeCmps1.engine.start(),
      nodeCmps2.switch.start(),
      nodeCmps2.blockDiscovery.start(),
      nodeCmps2.engine.start(),
    )

    # Use leaf addresses for want handles
    pendingBlocks1 = blocks2[0 .. 3].mapIt(
      nodeCmps1.pendingBlocks.getWantHandle(
        BlockAddress.init(manifest2.treeCid, blocks2.find(it).Natural)
      )
    )

    pendingBlocks2 = blocks1[0 .. 3].mapIt(
      nodeCmps2.pendingBlocks.getWantHandle(
        BlockAddress.init(manifest1.treeCid, blocks1.find(it).Natural)
      )
    )

    await nodeCmps1.switch.connect(
      nodeCmps2.switch.peerInfo.peerId, nodeCmps2.switch.peerInfo.addrs
    )

    await sleepAsync(100.millis) # give some time to exchange lists
    peerCtx2 = nodeCmps1.peerStore.get(nodeCmps2.switch.peerInfo.peerId)
    peerCtx1 = nodeCmps2.peerStore.get(nodeCmps1.switch.peerInfo.peerId)

    check isNil(peerCtx1).not
    check isNil(peerCtx2).not

  teardown:
    await allFuturesThrowing(
      nodeCmps1.blockDiscovery.stop(),
      nodeCmps1.engine.stop(),
      nodeCmps1.switch.stop(),
      nodeCmps2.blockDiscovery.stop(),
      nodeCmps2.engine.stop(),
      nodeCmps2.switch.stop(),
    )

  test "Should exchange blocks on connect":
    await allFuturesThrowing(allFinished(pendingBlocks1)).wait(10.seconds)
    await allFuturesThrowing(allFinished(pendingBlocks2)).wait(10.seconds)

    check:
      (
        await allFinished(
          (0 .. 3).mapIt(nodeCmps2.localStore.getBlock(manifest1.treeCid, it.Natural))
        )
      )
      .filterIt(it.completed and it.read.isOk)
      .mapIt($it.read.get.cid)
      .sorted(cmp[string]) == blocks1[0 .. 3].mapIt($it.cid).sorted(cmp[string])

      (
        await allFinished(
          (0 .. 3).mapIt(nodeCmps1.localStore.getBlock(manifest2.treeCid, it.Natural))
        )
      )
      .filterIt(it.completed and it.read.isOk)
      .mapIt($it.read.get.cid)
      .sorted(cmp[string]) == blocks2[0 .. 3].mapIt($it.cid).sorted(cmp[string])

  test "Should send want-have for block":
    let
      blk = bt.Block.new("Block 1".toBytes).tryGet()
      senderManifest =
        (await storeDataGetManifest(nodeCmps2.localStore, @[blk])).tryGet()

    # Attach manifest to sender's overlay
    discard (await nodeCmps2.localStore.storeManifest(senderManifest)).tryGet()
    # Pre-create overlay on receiver
    discard (await nodeCmps1.localStore.storeManifest(senderManifest)).tryGet()

    let blkFut = nodeCmps1.networkStore.getBlock(senderManifest.treeCid, 0.Natural)

    check eventually (
      await nodeCmps1.localStore.hasBlock(senderManifest.treeCid, 0.Natural)
    ).tryGet()
    check (await blkFut).tryGet() == blk

  test "Should get blocks from remote":
    let blocks = await allFinished(
      (4 .. 7).mapIt(nodeCmps1.networkStore.getBlock(manifest2.treeCid, it.Natural))
    )

    check blocks.mapIt(it.read().tryGet()) == blocks2[4 .. 7]

  test "Remote should send blocks when available":
    let blk = bt.Block.new("Block 1".toBytes).tryGet()

    # should fail retrieving block from remote
    check not await blk.cid in nodeCmps1.networkStore

    # Store as tree on sender
    let senderManifest =
      (await storeDataGetManifest(nodeCmps2.localStore, @[blk])).tryGet()

    # Attach manifest to sender's overlay
    discard (await nodeCmps2.localStore.storeManifest(senderManifest)).tryGet()
    # Pre-create overlay on receiver
    discard (await nodeCmps1.localStore.storeManifest(senderManifest)).tryGet()

    # should succeed retrieving block from remote
    let blkFut = nodeCmps1.networkStore.getBlock(senderManifest.treeCid, 0.Natural)
    check eventually (
      await nodeCmps1.localStore.hasBlock(senderManifest.treeCid, 0.Natural)
    ).tryGet()
    check (await blkFut).tryGet() == blk

asyncchecksuite "NetworkStore - multiple nodes":
  var
    cluster: NodesCluster
    nodes: seq[NodesComponents]
    blocks: seq[bt.Block]
    manifest0, manifest1, manifest2, manifest3: Manifest

  setup:
    blocks = (await makeRandomBlocks(datasetSize = 4096, blockSize = 256'nb)).tryGet
    cluster = await generateNodes(5)
    nodes = cluster.components

    # Store blocks as trees on each source node (4 blocks per node)
    manifest0 =
      (await storeDataGetManifest(nodes[0].localStore, blocks[0 .. 3])).tryGet()
    manifest1 =
      (await storeDataGetManifest(nodes[1].localStore, blocks[4 .. 7])).tryGet()
    manifest2 =
      (await storeDataGetManifest(nodes[2].localStore, blocks[8 .. 11])).tryGet()
    manifest3 =
      (await storeDataGetManifest(nodes[3].localStore, blocks[12 .. 15])).tryGet()

    # Attach manifests to their local overlays
    discard (await nodes[0].localStore.storeManifest(manifest0)).tryGet()
    discard (await nodes[1].localStore.storeManifest(manifest1)).tryGet()
    discard (await nodes[2].localStore.storeManifest(manifest2)).tryGet()
    discard (await nodes[3].localStore.storeManifest(manifest3)).tryGet()

    # Pre-create overlays on downloader (node 4) for the shards it will request
    discard (await nodes[4].localStore.storeManifest(manifest0)).tryGet()
    discard (await nodes[4].localStore.storeManifest(manifest3)).tryGet()

    for e in nodes:
      await e.engine.start()

    await allFuturesThrowing(nodes.mapIt(it.switch.start()))

  teardown:
    await allFuturesThrowing(nodes.mapIt(it.engine.stop()))
    await allFuturesThrowing(nodes.mapIt(it.blockDiscovery.stop()))
    await allFuturesThrowing(nodes.mapIt(it.switch.stop()))
    await allFuturesThrowing(nodes.mapIt(it.localStore.close()))
    if not cluster.isNil and not cluster.taskpool.isNil:
      cluster.taskpool.shutdown()
    nodes = @[]

  test "Should receive blocks for own want list":
    let
      downloader = nodes[4].networkStore
      engine = downloader.engine

    # Add blocks from 1st and 4th peers to want list using leaf addresses
    let pendingBlocks =
      (0 .. 3).mapIt(
        engine.pendingBlocks.getWantHandle(
          BlockAddress.init(manifest0.treeCid, it.Natural)
        )
      ) &
      (0 .. 3).mapIt(
        engine.pendingBlocks.getWantHandle(
          BlockAddress.init(manifest3.treeCid, it.Natural)
        )
      )

    await connectNodes(nodes)
    await sleepAsync(100.millis)

    await allFuturesThrowing(allFinished(pendingBlocks))

    check:
      (
        await allFinished(
          (0 .. 3).mapIt(downloader.localStore.getBlock(manifest0.treeCid, it.Natural)) &
            (0 .. 3).mapIt(
              downloader.localStore.getBlock(manifest3.treeCid, it.Natural)
            )
        )
      )
      .filterIt(it.completed and it.read.isOk)
      .mapIt($it.read.get.cid)
      .sorted(cmp[string]) ==
        (blocks[0 .. 3] & blocks[12 .. 15]).mapIt($it.cid).sorted(cmp[string])

  test "Should exchange blocks with multiple nodes":
    let
      downloader = nodes[4].networkStore
      engine = downloader.engine

    # Add blocks from 1st and 4th peers to want list
    let
      pendingBlocks1 = (0 .. 3).mapIt(
        engine.pendingBlocks.getWantHandle(
          BlockAddress.init(manifest0.treeCid, it.Natural)
        )
      )
      pendingBlocks2 = (0 .. 3).mapIt(
        engine.pendingBlocks.getWantHandle(
          BlockAddress.init(manifest3.treeCid, it.Natural)
        )
      )

    await connectNodes(nodes)
    await sleepAsync(100.millis)

    await allFuturesThrowing(allFinished(pendingBlocks1), allFinished(pendingBlocks2))

    check pendingBlocks1.mapIt(it.read.blk) == blocks[0 .. 3]
    check pendingBlocks2.mapIt(it.read.blk) == blocks[12 .. 15]

  test "Should return successful blocks when a batch request partially fails":
    let
      downloader = nodes[4].networkStore
      engine = downloader.engine
      addr0 = BlockAddress.init(manifest0.treeCid, 0.Natural)
      addr1 = BlockAddress.init(manifest0.treeCid, 1.Natural)

    # Start the batch getBlocks call — this creates handles internally
    let fut = downloader.getBlocks(manifest0.treeCid, @[0.Natural, 1.Natural])

    # Wait until both handles exist in engine.pendingBlocks
    require eventually(
      addr0 in engine.pendingBlocks and addr1 in engine.pendingBlocks, pollInterval = 10
    )

    # Resolve one handle with a real block
    await engine.pendingBlocks.resolve(
      @[BlockDelivery(blk: blocks[0], address: addr0)], BlockExcPeerCtx.none
    )

    # Fail the other handle explicitly
    await engine.pendingBlocks.failWantHandle(
      addr1, RequestAbandonedEngineError, "Simulated failure for partial-batch test"
    )

    # The batch should succeed with exactly the resolved block
    let result = await fut
    check result.isOk
    let returned = result.tryGet()
    check returned.len == 1
    check returned[0][0] == 0.Natural
    check returned[0][1].cid == blocks[0].cid

  test "Should return successful blocks when a direct-CID batch partially fails":
    let
      downloader = nodes[4].networkStore
      engine = downloader.engine
      cid0 = blocks[0].cid
      cid1 = blocks[1].cid

    let fut = downloader.getBlocks(@[cid0, cid1])

    require eventually(
      BlockAddress.init(cid0) in engine.pendingBlocks and
        BlockAddress.init(cid1) in engine.pendingBlocks,
      pollInterval = 10,
    )

    await engine.pendingBlocks.resolve(
      @[BlockDelivery(blk: blocks[0], address: BlockAddress.init(cid0))],
      BlockExcPeerCtx.none,
    )

    await engine.pendingBlocks.failWantHandle(
      BlockAddress.init(cid1),
      RequestAbandonedEngineError,
      "Simulated failure for direct-CID partial-batch test",
    )

    let result = await fut
    check result.isOk
    let returned = result.tryGet()
    check returned.len == 1
    check returned[0].cid == blocks[0].cid

  test "Should return successful tuples when getBlocksAndProofs partially fails":
    let
      downloader = nodes[4].networkStore
      engine = downloader.engine
      addr0 = BlockAddress.init(manifest0.treeCid, 0.Natural)
      addr1 = BlockAddress.init(manifest0.treeCid, 1.Natural)

    let fut = downloader.getBlocksAndProofs(manifest0.treeCid, @[0.Natural, 1.Natural])

    require eventually(
      addr0 in engine.pendingBlocks and addr1 in engine.pendingBlocks, pollInterval = 10
    )

    let sourceProof = (
      await nodes[0].localStore.getBlocksAndProofs(manifest0.treeCid, @[0.Natural])
    ).tryGet()[0][2]

    await engine.pendingBlocks.resolve(
      @[BlockDelivery(blk: blocks[0], address: addr0, proof: sourceProof)],
      BlockExcPeerCtx.none,
    )

    await engine.pendingBlocks.failWantHandle(
      addr1, RequestAbandonedEngineError,
      "Simulated failure for proof-bearing partial-batch test",
    )

    let result = await fut
    check result.isOk
    let returned = result.tryGet()
    check returned.len == 1
    check returned[0][0] == 0.Natural
    check returned[0][1].cid == blocks[0].cid

  test "Should not send leaf blocks without proofs":
    let
      downloader = nodes[4].networkStore
      blk = bt.Block.new("Block 1".toBytes).tryGet()
      tmpTreeCid = (await nodes[2].localStore.createTmpOverlay()).tryGet()
    check (await nodes[2].localStore.putBlock(tmpTreeCid, blk, 0)).isOk

    # Store the leaf without its proof (no putCidAndProof call)
    let (manifest, tree) = makeManifestAndTree(@[blk]).tryGet()
    let treeCid = manifest.treeCid
    check (await nodes[2].localStore.finalizeOverlay(tmpTreeCid, treeCid)).isOk
    check (await nodes[2].localStore.hasBlock(treeCid, 0.Natural)).tryGet()
    discard (await nodes[2].localStore.storeManifest(manifest)).tryGet()
    discard (await nodes[4].localStore.storeManifest(manifest)).tryGet()

    # The proofless leaf must not be delivered - the request stays pending
    let fut = downloader.getBlock(treeCid, 0.Natural)
    check not (await withTimeout(fut, 5.seconds))

  test "allFinishedFailed classifies cancelled futures as failures, not successes":
    proc work(): Future[int] {.async.} =
      await sleepAsync(50.millis)
      return 42

    proc cancelledWork(): Future[int] {.async.} =
      await sleepAsync(500.millis)
      return 99

    let
      good = work()
      bad = cancelledWork()

    await cancelAndWait(bad)

    let (succeeded, failed) = await allFinishedFailed[int](@[good, bad])

    check succeeded.len == 1
    check succeeded[0].value == 42
    check failed.len == 1
    check failed[0].cancelled
