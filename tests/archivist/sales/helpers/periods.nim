import pkg/archivist/marketplace/abstractmarketplace
import ../../helpers/mockclock

proc advanceToNextPeriod*(
    clock: MockClock, marketplace: AbstractMarketplace
) {.async.} =
  let periodicity = await marketplace.periodicity()
  let period = periodicity.periodOf(clock.now().Timestamp)
  let periodEnd = periodicity.periodEnd(period)
  clock.set(periodEnd.toSecondsSince1970 + 1)
