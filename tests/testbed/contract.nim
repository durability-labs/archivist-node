import pkg/ethers

type MarketplaceContract* = ref object of Contract

type RequestFulfilled* = object of Event
  requestId* {.indexed.}: array[32, byte]
