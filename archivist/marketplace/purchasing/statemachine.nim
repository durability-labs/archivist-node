import ../../utils/asyncstatemachine
import ../../clock
import ../../errors
import ../../utils/exponentialbackoff
import ../abstractmarketplace

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
    errorBackoff*: ExponentialBackoff = ExponentialBackoff()

  PurchaseState* = ref object of State
  PurchaseError* = object of ArchivistError
