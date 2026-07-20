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
import pkg/stew/io2
import pkg/questionable
import pkg/questionable/results
import pkg/kvstore
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
import ./chronos_observer

logScope:
  topics = "archivist node"

type
  NodeServer* = ref object
    config: NodeConf
    restServer: RestServerRef
    archivistNode: ArchivistNodeRef
    repoStore: RepoStore
    maintenance: BlockMaintainer
    natTraversal: NatTraversal
    discoveryStore: KVStore
    taskpool: Taskpool

  NodePrivateKey* = libp2p.PrivateKey # alias

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

  await s.natTraversal.start()

  let announceAddresses = s.archivistNode.switch.peerInfo.addrs
  let discoveryAddresses = discoveryAddresses(announceAddresses, s.config.discoveryPort)
  await s.natTraversal.mapPorts(discoveryAddresses) do(mapped: seq[MultiAddress]):
    s.archivistNode.discovery.updateDhtRecord(mapped)
  await s.natTraversal.mapPorts(announceAddresses) do(mapped: seq[MultiAddress]):
    s.archivistNode.discovery.updateAnnounceRecord(mapped)

  await s.connectMarketplace()
  await s.archivistNode.start()
  s.restServer.start()
  asyncSpawn chronosObserver(2.seconds)

proc stop*(s: NodeServer) {.async.} =
  notice "Stopping node"

  await s.restServer.stop()
  await s.archivistNode.stop()
  await s.maintenance.stop()
  await s.natTraversal.stop()
  await s.repoStore.stop()
  await s.archivistNode.switch.stop()

  if not s.discoveryStore.isNil:
    if err =? (await s.discoveryStore.close()).errorOption:
      error "Failed to close discovery store", err = err.msg

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

  info "Threadpool started", numThreads = tp.numThreads

  let discoveryDir = config.dataDir / ArchivistDhtNamespace

  if io2.createPath(discoveryDir).isErr:
    trace "Unable to create discovery directory for block store",
      discoveryDir = discoveryDir
    raise (ref Defect)(
      msg: "Unable to create discovery directory for block store: " & discoveryDir
    )

  let
    discoveryStore = KVStore(
      SQLiteKVStore.new(config.dataDir / ArchivistDhtProvidersNamespace, tp).expect(
        "Should create discovery datastore!"
      )
    )

    discovery = Discovery.new(
      switch.peerInfo.privateKey,
      announceAddrs = config.listenAddrs,
      bindPort = config.discoveryPort,
      bootstrapNodes = config.bootstrapNodes,
      store = discoveryStore,
    )

    network = BlockExcNetwork.new(switch)

    repoData: KVStore =
      case config.repoKind
      of repoFS:
        KVStore(
          FSKVStore
          .new(
            $config.dataDir,
            tp,
            depth = 5,
            directIO = config.fsDirectIO,
            fsyncFile = config.fsFsyncFile,
            fsyncDir = config.fsFsyncDir,
          )
          .expect("Should create repo file data store!")
        )
      of repoSQLite:
        KVStore(
          SQLiteKVStore.new($config.dataDir, tp).expect(
            "Should create repo SQLite data store!"
          )
        )

    repoStore = RepoStore.new(
      repoDs = repoData,
      metaDs = SQLiteKVStore.new(config.dataDir / ArchivistMetaNamespace, tp).expect(
          "Should create metadata store!"
        ),
      quotaMaxBytes = config.storageQuota,
      overlayTtl = config.overlayTtl.seconds,
    )

    maintenance =
      BlockMaintainer.new(repoStore, interval = config.overlayMaintenanceInterval)

    natTraversal = NatTraversal.new(config.nat, config.natRenewal, tp)

    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new()
    advertiser = Advertiser.new(repoStore, discovery)
    blockDiscovery =
      DiscoveryEngine.new(repoStore, peerStore, network, discovery, pendingBlocks)
    engine = BlockExcEngine.new(
      repoStore, network, blockDiscovery, advertiser, peerStore, pendingBlocks
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
      repoStore = repoStore,
      engine = engine,
      discovery = discovery,
      prover = prover,
      taskPool = tp,
      fetchOrder = config.fetchOrder,
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
    natTraversal: natTraversal,
    discoveryStore: discoveryStore,
    taskpool: tp,
  )
