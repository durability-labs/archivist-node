import std/sequtils
import std/algorithm
import std/importutils

import pkg/chronos
import pkg/stew/byteutils

import pkg/archivist/stores
import pkg/archivist/blockexchange
import pkg/archivist/chunker
import pkg/archivist/discovery
import pkg/archivist/blocktype as bt
import pkg/archivist/manifest

import ../../../asynctest
import ../../examples
import ../../helpers

import ../../helpers/nodeutils

asyncchecksuite "NetworkStore engine - 2 nodes":
  var
    nodeCmps1, nodeCmps2: NodesComponents
    peerCtx1, peerCtx2: BlockExcPeerCtx
    pricing1, pricing2: Pricing
    blocks1, blocks2: seq[bt.Block]
    manifest1, manifest2: Manifest
    pendingBlocks1, pendingBlocks2: seq[BlockHandle]

  setup:
    blocks1 = (await makeRandomBlocks(datasetSize = 2048, blockSize = 256'nb)).tryGet
    blocks2 = (await makeRandomBlocks(datasetSize = 2048, blockSize = 256'nb)).tryGet
    nodeCmps1 = generateNodes(1).components[0]
    nodeCmps2 = generateNodes(1).components[0]

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

    pricing1 = Pricing.example()
    pricing2 = Pricing.example()

    pricing1.address = nodeCmps1.wallet.address
    pricing2.address = nodeCmps2.wallet.address
    nodeCmps1.engine.pricing = pricing1.some
    nodeCmps2.engine.pricing = pricing2.some

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

  test "Should exchanges accounts on connect":
    check peerCtx1.account .? address == pricing1.address.some
    check peerCtx2.account .? address == pricing2.address.some

  test "Should send want-have for block":
    let
      blk = bt.Block.new("Block 1".toBytes).tryGet()
      senderManifest =
        (await storeDataGetManifest(nodeCmps2.localStore, @[blk])).tryGet()

    # Attach manifest to sender's overlay
    discard (await nodeCmps2.localStore.storeManifest(senderManifest)).tryGet()
    # Pre-create overlay on receiver
    discard (await nodeCmps1.localStore.storeManifest(senderManifest)).tryGet()

    let
      leafAddr = BlockAddress.init(senderManifest.treeCid, 0.Natural)
      blkFut = nodeCmps1.pendingBlocks.getWantHandle(leafAddr)

    let entry = WantListEntry(
      address: leafAddr,
      priority: 1,
      cancel: false,
      wantType: WantType.WantBlock,
      sendDontHave: false,
    )

    peerCtx1.peerWants.add(entry)
    check nodeCmps2.engine.taskQueue.pushOrUpdateNoWait(peerCtx1).isOk

    check eventually (
      await nodeCmps1.localStore.hasBlock(senderManifest.treeCid, 0.Natural)
    ).tryGet()
    check eventually (await blkFut) == blk

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
    check await nodeCmps1.networkStore
    .getBlock(senderManifest.treeCid, 0.Natural)
    .withTimeout(100.millis)

  test "Should receive payments for blocks that were sent":
    # blocks2 already stored as tree on nodeCmps2, overlay on nodeCmps1
    discard await allFinished(
      (4 .. 7).mapIt(nodeCmps1.networkStore.getBlock(manifest2.treeCid, it.Natural))
    )

    let
      channel = !peerCtx1.paymentChannel
      wallet = nodeCmps2.wallet

    check eventually wallet.balance(channel, Asset) > 0

asyncchecksuite "NetworkStore - multiple nodes":
  var
    nodes: seq[NodesComponents]
    blocks: seq[bt.Block]
    manifest0, manifest1, manifest2, manifest3: Manifest

  setup:
    blocks = (await makeRandomBlocks(datasetSize = 4096, blockSize = 256'nb)).tryGet
    nodes = generateNodes(5)

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
    await allFuturesThrowing(nodes.mapIt(it.switch.stop()))

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

    check pendingBlocks1.mapIt(it.read) == blocks[0 .. 3]
    check pendingBlocks2.mapIt(it.read) == blocks[12 .. 15]
