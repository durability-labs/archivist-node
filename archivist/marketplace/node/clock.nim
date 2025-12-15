import pkg/questionable/results
import pkg/ethers
import ../../clock
import ../../systemclock
import ../contracts/clock
import ./options

proc start*(
    _: type Clock, provider: Provider, options: MarketplaceOptions
): Future[?!Clock] {.async: (raises: [CancelledError]).} =
  let clock =
    if options.useSystemClock:
      SystemClock.new()
    else:
      OnChainClock.new(provider)
  try:
    await clock.start()
    success clock
  except CancelledError as error:
    raise error
  except CatchableError as error:
    failure error
