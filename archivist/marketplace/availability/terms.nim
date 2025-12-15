import pkg/stint
import pkg/questionable
import ../../clock

export stint.UInt256
export clock.SecondsSince1970

type AvailabilityTerms* = object
  minimumPricePerBytePerSecond*: UInt256
  maximumCollateralPerByte*: UInt256
  maximumDuration*: uint64
  availableUntil*: ?SecondsSince1970
