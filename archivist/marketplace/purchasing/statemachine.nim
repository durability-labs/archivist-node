import ../../utils/asyncstatemachine
import ../abstractmarketplace
import ../../clock
import ../../errors

export abstractmarketplace
export clock
export asyncstatemachine

type
  Purchase* = ref object of Machine
    future*: Future[void]
    marketplace*: AbstractMarketplace
    clock*: Clock
    requestId*: RequestId
    request*: ?StorageRequest

  PurchaseState* = ref object of State
  PurchaseError* = object of ArchivistError
