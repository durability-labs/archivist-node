import pkg/ethers
import pkg/chronos
import pkg/questionable/results
import pkg/datastore/typedds
import ../purchasing
import ../sales
import ../validation
import ../contracts/marketplacecontract
import ../contracts/clock
import ./options
import ./provider
import ./wallet
import ./address
import ./onchainmarketplace
import ./clock
import ./availability/store
import ./validation
import ./storageinterface

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
    datastore: TypedDatastore,
    options = MarketplaceOptions(),
): Future[?!MarketplaceNode] {.async: (raises: [CancelledError]).} =
  let provider = ?await Provider.connect(ethProviderUrl, options)
  let marketplaceAddress = ?await getMarketplaceAddress(provider, options)
  let wallet = ?loadWallet(ethPrivateKeyFile, provider)
  let contract = ?catch MarketplaceContract.new(marketplaceAddress, wallet)
  let marketplace = OnchainMarketplace.new(contract, options)
  let clock = ?await Clock.start(provider, options)
  let purchasing = Purchasing.new(marketplace, clock)
  let availability = AvailabilityStore.new(datastore)
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
  ?await node.provider.waitForSync()
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
