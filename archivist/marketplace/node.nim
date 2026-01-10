import pkg/ethers
import pkg/chronos
import pkg/kvstore
import pkg/questionable/results
import ./purchasing
import ./sales
import ./validation
import ./contracts/marketplacecontract
import ./contracts/clock
import ./availability/store
import ./storageinterface
import ./node/options
import ./node/provider
import ./node/wallet
import ./node/address
import ./node/onchainmarketplace
import ./node/clock
import ./node/validation

type MarketplaceNode* = ref object
  clock: Clock
  provider: Provider
  address: Address
  purchasing: Purchasing
  sales: Sales
  validation: ?Validation

proc connect*(
    _: type MarketplaceNode,
    ethProviderUrl: string,
    ethPrivateKeyFile: string,
    storage: StorageInterface,
    metaStore: KVStore,
    options = MarketplaceOptions(),
): Future[?!MarketplaceNode] {.async: (raises: [CancelledError]).} =
  let provider = ?await Provider.connect(ethProviderUrl, options)
  ?await provider.waitForSync()
  let marketplaceAddress = ?await getMarketplaceAddress(provider, options)
  let wallet = ?loadWallet(ethPrivateKeyFile, provider)
  let contract = ?catch MarketplaceContract.new(marketplaceAddress, wallet)
  let marketplace = ?await OnchainMarketplace.load(contract, options)
  let clock = ?await Clock.start(provider, options)
  let purchasing = Purchasing.new(marketplace, clock)
  let availability = AvailabilityStore.new(metaStore)
  let sales = Sales.new(marketplace, clock, availability, storage)
  var validation: ?Validation
  if options.validationEnabled:
    validation = some ?Validation.new(marketplace, clock, options)
  success MarketplaceNode(
    clock: clock,
    provider: provider,
    address: wallet.address,
    purchasing: purchasing,
    sales: sales,
    validation: validation,
  )

proc start*(
    node: MarketplaceNode
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ?await node.purchasing.start()
  ?await node.sales.start()
  if validation =? node.validation:
    ?await validation.start()
  success()

proc stop*(marketplace: MarketplaceNode) {.async: (raises: []).} =
  await marketplace.purchasing.stop()
  await marketplace.sales.stop()
  if validation =? marketplace.validation:
    await validation.stop()
  await marketplace.clock.stop()
  try:
    await noCancel marketplace.provider.close()
  except ProviderError:
    discard

func clock*(marketplace: MarketplaceNode): Clock =
  marketplace.clock

func address*(marketplace: MarketplaceNode): Address =
  marketplace.address

func purchasing*(marketplace: MarketplaceNode): Purchasing =
  marketplace.purchasing

func sales*(marketplace: MarketplaceNode): Sales =
  marketplace.sales
