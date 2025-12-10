import pkg/chronos
import pkg/questionable/results
import pkg/libp2p/builders
import pkg/nitro/wallet
import pkg/taskpools
import pkg/archivist/discovery
import pkg/archivist/stores
import pkg/archivist/blockexchange
import pkg/archivist/node
import ../../helpers/templeveldb

type TemporaryNode* = ref object
  tempRepoDb: TempLevelDb
  tempMetaDb: TempLevelDb
  localStore: RepoStore
  p2p: Switch
  peerStore: PeerCtxStore
  exchangeNetwork: BlockExcNetwork
  discoveryNetwork: Discovery
  pendingBlocks: PendingBlocksManager
  discoveryEngine: DiscoveryEngine
  exchangeEngine: BlockExcEngine
  networkStore: NetworkStore
  node: ArchivistNodeRef

proc initializeLocalStore(temporary: TemporaryNode) =
  temporary.tempRepoDb = TempLevelDb.new()
  temporary.tempMetaDb = TempLevelDb.new()
  let repoDs = temporary.tempRepoDb.newDb()
  let metaDs = temporary.tempMetaDb.newDb()
  temporary.localStore = RepoStore.new(repoDs, metaDs)

proc initializeNetwork(temporary: TemporaryNode) =
  temporary.p2p = newStandardSwitch()
  temporary.peerStore = PeerCtxStore.new()
  temporary.exchangeNetwork = BlockExcnetwork.new(temporary.p2p)
  let privateKey = temporary.p2p.peerInfo.privateKey
  let address = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()
  temporary.discoveryNetwork = Discovery.new(privateKey, announceAddrs = @[address])

proc initializePendingBlocks(temporary: TemporaryNode) =
  temporary.pendingBlocks = PendingBlocksManager.new()

proc initializeDiscovery(temporary: TemporaryNode) =
  temporary.discoveryEngine = DiscoveryEngine.new(
    temporary.localStore, temporary.peerStore, temporary.exchangeNetwork,
    temporary.discoveryNetwork, temporary.pendingBlocks,
  )

proc initializeBlockExchange(temporary: TemporaryNode) =
  let wallet = WalletRef.new(EthPrivateKey.random())
  let advertiser = Advertiser.new(temporary.localStore, temporary.discoveryNetwork)
  temporary.exchangeEngine = BlockExcEngine.new(
    temporary.localStore, wallet, temporary.exchangeNetwork, temporary.discoveryEngine,
    advertiser, temporary.peerStore, temporary.pendingBlocks,
  )

proc initializeNetworkStore(temporary: TemporaryNode) =
  temporary.networkStore =
    NetworkStore.new(temporary.exchangeEngine, temporary.localStore)

proc initializeNode(temporary: TemporaryNode) =
  temporary.node = ArchivistNodeRef.new(
    temporary.p2p,
    temporary.networkStore,
    temporary.exchangeEngine,
    temporary.discoveryNetwork,
    Taskpool.new(),
  )

proc create*(_: type TemporaryNode): Future[TemporaryNode] {.async.} =
  let temporary = TemporaryNode()
  temporary.initializeLocalStore()
  temporary.initializeNetwork()
  temporary.initializePendingBlocks()
  temporary.initializeDiscovery()
  temporary.initializeBlockExchange()
  temporary.initializeNetworkStore()
  temporary.initializeNode()
  await temporary.node.start()
  temporary

proc destroy*(temporary: TemporaryNode) {.async.} =
  await temporary.node.stop()
  await temporary.tempRepoDb.destroyDb()
  await temporary.tempMetaDb.destroyDb()

func node*(temporary: TemporaryNode): ArchivistNodeRef =
  temporary.node

func localStore*(temporary: TemporaryNode): RepoStore =
  temporary.localStore

func networkStore*(temporary: TemporaryNode): NetworkStore =
  temporary.networkStore
