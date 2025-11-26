## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils
import std/strutils
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
import pkg/stew/io2

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
import ./contracts
import ./systemclock
import ./contracts/clock
import ./contracts/deployment
import ./utils/addrutils
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
    archivistNode: ArchivistNodeRef
    repoStore: RepoStore
    maintenance: BlockMaintainer
    taskpool: Taskpool

  NodePrivateKey* = libp2p.PrivateKey # alias
  EthWallet = ethers.Wallet

proc waitForSync(provider: Provider): Future[void] {.async.} =
  var sleepTime = 1
  trace "Checking sync state of Ethereum provider..."
  while await provider.isSyncing:
    notice "Waiting for Ethereum provider to sync..."
    await sleepAsync(sleepTime.seconds)
    if sleepTime < 10:
      inc sleepTime
  trace "Ethereum provider is synced."

proc getClock(s: NodeServer, provider: JsonRpcProvider): Clock =
  if s.config.useSystemClock:
    return SystemClock()
  if s.config.validator or s.config.persistence:
    return OnChainClock.new(provider)
  return SystemClock()

proc bootstrapInteractions(s: NodeServer): Future[void] {.async.} =
  ## bootstrap interactions and return contracts
  ## using clients, hosts, validators pairings
  ##
  let
    config = s.config
    repo = s.repoStore

  if config.persistence:
    if not config.ethAccount.isSome and not config.ethPrivateKey.isSome:
      error "Persistence enabled, but no Ethereum account was set"
      quit QuitFailure

    let provider = await JsonRpcProvider.connect(
      config.ethProvider, maxPriorityFeePerGas = config.maxPriorityFeePerGas.u256
    )
    await waitForSync(provider)
    var signer: Signer
    if account =? config.ethAccount:
      signer = provider.getSigner(account)
    elif keyFile =? config.ethPrivateKey:
      without isSecure =? checkSecureFile(keyFile):
        error "Could not check file permissions: does Ethereum private key file exist?"
        quit QuitFailure
      if not isSecure:
        error "Ethereum private key file does not have safe file permissions"
        quit QuitFailure
      without key =? keyFile.readAllChars():
        error "Unable to read Ethereum private key file"
        quit QuitFailure
      without wallet =? EthWallet.new(key.strip(), provider):
        error "Invalid Ethereum private key in file"
        quit QuitFailure
      signer = wallet

    without var marketplaceAddress =? config.marketplaceAddress:
      without lookup =? await provider.getMarketplaceAddress(), e:
        error "No marketplace address specified or found", error = e.msg
        quit QuitFailure
      marketplaceAddress = lookup

    let contract = MarketplaceContract.new(marketplaceAddress, signer)
    let marketplace = OnChainMarketplace.new(
      contract, config.rewardRecipient, config.marketplaceRequestCacheSize
    )

    let clock = s.getClock(provider)
    s.archivistNode.clock = clock

    var client: ?ClientInteractions
    var host: ?HostInteractions
    var validator: ?ValidatorInteractions

    if error =? (await marketplace.loadConfig()).errorOption:
      fatal "Cannot load marketplace configuration", error = error.msg
      quit QuitFailure

    let purchasing = Purchasing.new(marketplace, clock)
    let sales = Sales.new(marketplace, clock, repo)
    client = some ClientInteractions.new(clock, purchasing)
    host = some HostInteractions.new(clock, sales)

    if config.validator:
      without validationConfig =?
        ValidationConfig.init(
          config.validatorMaxSlots, config.validatorGroups, config.validatorGroupIndex
        ), err:
        error "Invalid validation parameters", err = err.msg
        quit QuitFailure
      let validation = Validation.new(clock, marketplace, validationConfig)
      validator = some ValidatorInteractions.new(clock, validation)

    s.archivistNode.contracts = (client, host, validator)

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

  await s.bootstrapInteractions()
  await s.archivistNode.start()
  s.restServer.start()

proc stop*(s: NodeServer) {.async.} =
  notice "Stopping node"

  let res = await noCancel allFinishedFailed[void](
    @[
      s.restServer.stop(),
      s.archivistNode.switch.stop(),
      s.archivistNode.stop(),
      s.repoStore.stop(),
      s.maintenance.stop(),
    ]
  )

  if res.failure.len > 0:
    error "Failed to stop node", failures = res.failure.len
    raiseAssert "Failed to stop node"

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
    discoveryStore = Datastore(
      LevelDbDatastore.new(config.dataDir / ArchivistDhtProvidersNamespace).expect(
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
  )
