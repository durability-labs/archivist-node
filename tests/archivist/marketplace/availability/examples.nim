import archivist/marketplace/availability/terms
import ../../../examples

export examples.example

proc example*(_: type AvailabilityTerms): AvailabilityTerms =
  AvailabilityTerms(
    minimumPricePerBytePerSecond: TokensPerSecond.example,
    maximumCollateralPerByte: Tokens.example,
    maximumDuration: StorageDuration.example,
    availableUntil: some StorageTimestamp.example,
  )
