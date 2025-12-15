import archivist/marketplace/availability/terms
import ../../../examples

export example

proc example*(_: type AvailabilityTerms): AvailabilityTerms =
  AvailabilityTerms(
    minimumPricePerBytePerSecond: UInt256.example,
    maximumCollateralPerByte: UInt256.example,
    maximumDuration: uint64.example,
    availableUntil: some SecondsSince1970.example,
  )
