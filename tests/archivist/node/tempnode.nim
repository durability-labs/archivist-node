import pkg/chronos
import pkg/questionable/results
import pkg/libp2p/builders
import pkg/nitro/wallet
import pkg/taskpools
import pkg/kvstore
import pkg/archivist/discovery
import pkg/archivist/stores
import pkg/archivist/blockexchange
import pkg/archivist/node

type TemporaryNode* = ref object
  repoDs: KVStore
  metaDs: KVStore
  tp: Taskpool
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
  temporary.tp = Taskpool.new(num_threads = 4)
  temporary.repoDs = SQLiteKVStore.new(SqliteMemory, temporary.tp).tryGet()
  temporary.metaDs = SQLiteKVStore.new(SqliteMemory, temporary.tp).tryGet()
  temporary.localStore = RepoStore.new(temporary.repoDs, temporary.metaDs)

proc initializeNetwork(temporary: TemporaryNode) =
  temporary.p2p = newStandardSwitch()
  temporary.peerStore = PeerCtxStore.new()
  temporary.exchangeNetwork = BlockExcnetwork.new(temporary.p2p)
  let privateKey = temporary.p2p.peerInfo.privateKey
  let address = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()
  let discoveryDs = SQLiteKVStore.new(SqliteMemory, temporary.tp).tryGet()
  temporary.discoveryNetwork =
    Discovery.new(privateKey, announceAddrs = @[address], store = discoveryDs)

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
  (await temporary.repoDs.close()).tryGet()
  (await temporary.metaDs.close()).tryGet()
  temporary.tp.shutdown()

func node*(temporary: TemporaryNode): ArchivistNodeRef =
  temporary.node

func localStore*(temporary: TemporaryNode): RepoStore =
  temporary.localStore

func networkStore*(temporary: TemporaryNode): NetworkStore =
  temporary.networkStore
