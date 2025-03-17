import pkg/chronos
import pkg/questionable/results
import ../contracts/onchainmarketplace
import ../contracts/marketplacecontract
import ./options

export onchainmarketplace.OnchainMarketplace

proc load*(
    _: type OnchainMarketplace,
    contract: MarketplaceContract,
    options: MarketplaceOptions,
): Future[?!OnchainMarketplace] {.async: (raises: [CancelledError]).} =
  await OnchainMarketplace.load(
    contract, options.requestCacheSize
  )
