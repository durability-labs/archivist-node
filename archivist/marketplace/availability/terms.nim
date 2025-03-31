import pkg/questionable
import ../timestamps
import ../tokens

export timestamps.StorageDuration
export timestamps.StorageTimestamp
export tokens.Tokens
export tokens.TokensPerSecond

type AvailabilityTerms* = object
  minimumPricePerBytePerSecond*: TokensPerSecond
  maximumCollateralPerByte*: Tokens
  maximumDuration*: StorageDuration
  availableUntil*: ?StorageTimestamp
