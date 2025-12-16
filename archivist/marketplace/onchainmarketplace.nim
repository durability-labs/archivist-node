import ../contracts/onchainmarketplace
import ../contracts/marketplacecontract
import ./options

export onchainmarketplace.OnchainMarketplace

func new*(
    _: type OnchainMarketplace,
    contract: MarketplaceContract,
    options: MarketplaceOptions,
): OnchainMarketplace =
  OnchainMarketplace.new(contract, options.rewardRecipient, options.requestCacheSize)
