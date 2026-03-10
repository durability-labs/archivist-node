## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/os
import std/tables
import std/cpuinfo

import pkg/chronos
import pkg/taskpools
import pkg/presto
import pkg/libp2p
import pkg/confutils
import pkg/confutils/defs
import pkg/nitro
import pkg/stew/io2
import pkg/datastore
import pkg/ethers except Rng

import ./node
import ./conf
import ./rng as random
import ./rest/api
import ./stores
import ./slots
import ./blockexchange
import ./utils/fileutils
import ./erasure
import ./discovery
import ./marketplace
import ./marketplacestorage
import ./namespaces
import ./archivisttypes
import ./logutils
import ./nat

logScope:
  topics = "archivist node"

type
  NodeServer* = ref object
    config: NodeConf
    restServer: RestServerRef
    archivistNode*: ArchivistNodeRef
    repoStore: RepoStore
    maintenance: BlockMaintainer
    taskpool: Taskpool
    started: bool  # Track whether the node was started
    discoveryStore: Datastore  # Store reference to close explicitly

  NodePrivateKey* = libp2p.PrivateKey # alias

func node*(self: NodeServer): ArchivistNodeRef =
  return self.archivistNode

func repoStore*(self: NodeServer): RepoStore =
  return self.repoStore

func dataDir*(self: NodeServer): string =
  return string(self.config.dataDir)

func config*(self: NodeServer): NodeConf =
  return self.config

proc connectMarketplace(s: NodeServer) {.async.} =
  let config = s.config

  if config.persistence:
    without ethPrivateKeyFile =? config.ethPrivateKey:
      error "Persistence enabled, but no Ethereum private key was set"
      quit QuitFailure

    let marketplaceResult = await MarketplaceNode.connect(
      ethProviderUrl = config.ethProvider,
      ethPrivateKeyFile = ethPrivateKeyFile,
      datastore = s.repoStore.metaDs,
      storage = MarketplaceStorage.new(s.archivistNode, s.repoStore),
      options = MarketplaceOptions(
        marketplaceAddress: config.marketplaceAddress,
        maxPriorityFeePerGas: config.maxPriorityFeePerGas,
        requestCacheSize: config.marketplaceRequestCacheSize,
        validationEnabled: config.validator,
        validationMaxSlots: some config.validatorMaxSlots,
        validationGroups: config.validatorGroups,
        validationGroupIndex: some config.validatorGroupIndex,
        useSystemClock: config.useSystemClock,
      ),
    )

    without marketplace =? marketplaceResult, err:
      error "Unable to connect to marketplace", error = err.msg
      quit QuitFailure

    s.archivistNode.marketplace = marketplace

proc start*(s: NodeServer) {.async.} =
  trace "Starting node", config = $s.config

  when defined(archivist_system_testing_options):
    warn "Warning: This application was compiled with system testing options enabled. " &
      "It is strongly recommended to use it for development purposes only."

  await s.repoStore.start()
  s.maintenance.start()

  await s.archivistNode.switch.start()

  let (announceAddrs, discoveryAddrs) = nattedAddress(
    s.config.nat, s.archivistNode.switch.peerInfo.addrs, s.config.discoveryPort
  )

  s.archivistNode.discovery.updateAnnounceRecord(announceAddrs)
  s.archivistNode.discovery.updateDhtRecord(discoveryAddrs)

  await s.connectMarketplace()
  await s.archivistNode.start()
  s.restServer.start()
  s.started = true

proc stop*(s: NodeServer) {.async.} =
  notice "Stopping node"

  if not s.started:
    # Close the discovery store to release the LevelDB lock
    if not s.discoveryStore.isNil:
      try:
        discard await s.discoveryStore.close()
      except Exception as e:
        error "Failed to close discovery store", error = e.msg
    if not s.taskpool.isNil:
      s.taskpool.shutdown()
    return

  var futures: seq[Future[void]] = @[]
  
  if not s.restServer.isNil:
    futures.add(s.restServer.stop())
  
  if not s.archivistNode.isNil:
    futures.add(s.archivistNode.switch.stop())
    futures.add(s.archivistNode.stop())
  
  if not s.repoStore.isNil:
    futures.add(s.repoStore.stop())
  
  if not s.maintenance.isNil:
    futures.add(s.maintenance.stop())
  
  if futures.len > 0:
    let res = await noCancel allFinishedFailed[void](futures)
    
    if res.failure.len > 0:
      error "Failed to stop node", failures = res.failure.len
      raiseAssert "Failed to stop node"

  # Close the discovery store to release the LevelDB lock
  if not s.discoveryStore.isNil:
    try:
      discard await s.discoveryStore.close()
    except Exception as e:
      error "Failed to close discovery store", error = e.msg
  if not s.taskpool.isNil:
    s.taskpool.shutdown()

proc new*(
    T: type NodeServer, config: NodeConf, privateKey: NodePrivateKey
): NodeServer =
  ## create NodeServer including setting up datastore, repostore, etc
  let switch = SwitchBuilder
    .new()
    .withPrivateKey(privateKey)
    .withAddresses(config.listenAddrs)
    .withRng(random.Rng.instance())
    .withNoise()
    .withMplex(5.minutes, 5.minutes)
    .withMaxConnections(config.maxPeers)
    .withAgentVersion(config.agentString)
    .withSignedPeerRecord(true)
    .withTcpTransport({ServerFlags.ReuseAddr})
    .build()

  let numThreads =
    if int(config.numThreads) == 0:
      countProcessors()
    else:
      int(config.numThreads)

  var tp =
    try:
      Taskpool.new(numThreads)
    except CatchableError as exc:
      raiseAssert("Failure in tp initialization:" & exc.msg)

  let discoveryDir = config.dataDir / ArchivistDhtNamespace

  if io2.createPath(discoveryDir).isErr:
    raise (ref Defect)(
      msg: "Unable to create discovery directory for block store: " & discoveryDir
    )

  let discoveryProvidersDir = config.dataDir / ArchivistDhtProvidersNamespace
  if io2.createPath(discoveryProvidersDir).isErr:
    raise (ref Defect)(
      msg: "Unable to create discovery providers directory: " & discoveryProvidersDir
    )

  let
    discoveryStore = Datastore(
      LevelDbDatastore.new(discoveryProvidersDir).expect(
        "Should create discovery datastore!"
      )
    )

  let
    discovery = Discovery.new(
      switch.peerInfo.privateKey,
      announceAddrs = config.listenAddrs,
      bindPort = config.discoveryPort,
      bootstrapNodes = config.bootstrapNodes,
      store = discoveryStore,
    )

    wallet = WalletRef.new(EthPrivateKey.random())
    network = BlockExcNetwork.new(switch)

    repoData =
      case config.repoKind
      of repoFS:
        Datastore(
          FSDatastore.new($config.dataDir, depth = 5).expect(
            "Should create repo file data store!"
          )
        )
      of repoSQLite:
        Datastore(
          SQLiteDatastore.new($config.dataDir).expect(
            "Should create repo SQLite data store!"
          )
        )
      of repoLevelDb:
        Datastore(
          LevelDbDatastore.new($config.dataDir).expect(
            "Should create repo LevelDB data store!"
          )
        )

    repoStore = RepoStore.new(
      repoDs = repoData,
      metaDs = LevelDbDatastore.new(config.dataDir / ArchivistMetaNamespace).expect(
          "Should create metadata store!"
        ),
      quotaMaxBytes = config.storageQuota,
      blockTtl = config.blockTtl,
    )

    maintenance = BlockMaintainer.new(
      repoStore,
      interval = config.blockMaintenanceInterval,
      numberOfBlocksPerInterval = config.blockMaintenanceNumberOfBlocks,
    )

    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new()
    advertiser = Advertiser.new(repoStore, discovery)
    blockDiscovery =
      DiscoveryEngine.new(repoStore, peerStore, network, discovery, pendingBlocks)
    engine = BlockExcEngine.new(
      repoStore, wallet, network, blockDiscovery, advertiser, peerStore, pendingBlocks
    )
    store = NetworkStore.new(engine, repoStore)
    prover =
      if config.prover:
        let prover = config.initializeProver(tp).expect("Unable to create prover.")
        some prover
      else:
        none Prover

    archivistNode = ArchivistNodeRef.new(
      switch = switch,
      networkStore = store,
      engine = engine,
      discovery = discovery,
      prover = prover,
      taskPool = tp,
    )

    restServer = RestServerRef
      .new(
        archivistNode.initRestApi(config, repoStore, config.apiCorsAllowedOrigin),
        initTAddress(config.apiBindAddress, config.apiPort),
        bufferSize = (1024 * 64),
        maxRequestBodySize = int.high,
      )
      .expect("Should create rest server!")

  switch.mount(network)

  NodeServer(
    config: config,
    archivistNode: archivistNode,
    restServer: restServer,
    repoStore: repoStore,
    maintenance: maintenance,
    taskpool: tp,
    discoveryStore: discoveryStore,
    started: false,
  )
