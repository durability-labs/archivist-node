import pkg/ethers
import ../contracts/config
import ../validationconfig

type MarketplaceOptions* = object
  marketplaceAddress*: ?Address
  rewardRecipient*: ?Address
  maxPriorityFeePerGas*: uint64 = DefaultMaxPriorityFeePerGas
  requestCacheSize*: uint16 = DefaultRequestCacheSize
  validationEnabled*: bool
  validationMaxSlots*: ?MaxSlots
  validationGroups*: ?ValidationGroups
  validationGroupIndex*: ?uint16
  useSystemClock*: bool
