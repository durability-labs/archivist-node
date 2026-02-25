import pkg/ethers
import pkg/chronos
import pkg/questionable/results
import ../../logutils
import ./options

proc connect*(
    _: type Provider, url: string, options: MarketplaceOptions
): Future[?!Provider] {.async: (raises: [CancelledError]).} =
  try:
    let jsonRpcOptions = JsonRpcOptions(
      maxPriorityFeePerGas: options.maxPriorityFeePerGas.u256,
      httpConcurrencyLimit: some 10,
    )
    let provider = await JsonRpcProvider.connect(url, jsonRpcOptions)
    success Provider(provider)
  except JsonRpcProviderError as error:
    failure error

proc waitForSync*(
    provider: Provider
): Future[?!void] {.async: (raises: [CancelledError]).} =
  logScope:
    topics = "marketplace node sync"
  try:
    var sleepTime = 1
    trace "Checking sync state of Ethereum provider..."
    while await provider.isSyncing:
      notice "Waiting for Ethereum provider to sync..."
      await sleepAsync(sleepTime.seconds)
      if sleepTime < 10:
        inc sleepTime
    trace "Ethereum provider is synced."
    success()
  except ProviderError as error:
    failure error
