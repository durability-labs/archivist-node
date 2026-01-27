import pkg/ethers
import ./contract/ask

export ask.StorageAsk
export ask.solidityType
export ask.encode
export ask.decode

type MarketplaceContract* = ref object of Contract

type StorageRequested* = object of Event
  requestId*: array[32, byte]
  ask*: StorageAsk
  expiry*: StUint[40]

type SlotFilled* = object of Event
  requestId* {.indexed.}: array[32, byte]
  slotIndex*: uint64

type RequestFulfilled* = object of Event
  requestId* {.indexed.}: array[32, byte]

type RequestFailed* = object of Event
  requestId* {.indexed.}: array[32, byte]

type ProofSubmitted* = object of Event
  id*: array[32, byte]

type SlotFreed* = object of Event
  requestId* {.indexed.}: array[32, byte]
  slotIndex*: uint64

proc token*(marketplace: MarketplaceContract): Address {.contract, view.}
