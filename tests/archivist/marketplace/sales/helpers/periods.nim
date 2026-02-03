import pkg/archivist/marketplace/abstractmarketplace
import ../../../helpers/mockclock

proc advanceToNextPeriod*(
    clock: MockClock, marketplace: AbstractMarketplace
) {.async.} =
  let periodicity = marketplace.periodicity()
  let period = periodicity.periodOf(clock.now())
  let periodEnd = periodicity.periodEnd(period)
  clock.set(periodEnd.toSecondsSince1970 + 1)
