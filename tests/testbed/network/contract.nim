import pkg/ethers

type MarketplaceContract* = ref object of Contract

type RequestFulfilled* = object of Event
  requestId* {.indexed.}: array[32, byte]

type ProofSubmitted* = object of Event
  id*: array[32, byte]

type SlotFreed* = object of Event
  requestId* {.indexed.}: array[32, byte]
  slotIndex*: uint64
