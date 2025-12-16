import pkg/ethers
import pkg/questionable
import pkg/questionable/results
import ../contracts/deployment
import ./options

proc getMarketplaceAddress*(
    provider: Provider, options: MarketplaceOptions
): Future[?!Address] {.async: (raises: [CancelledError]).} =
  if address =? options.marketplaceAddress:
    return success address
  await deployment.getMarketplaceAddress(provider)
