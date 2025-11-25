import std/tables
import pkg/stint
import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/nimcrypto
import ./marketplace/abstractmarketplace
import ./clock
import ./purchasing/purchase

export questionable
export chronos
export abstractmarketplace
export purchase

type
  Purchasing* = ref object
    marketplace*: AbstractMarketplace
    clock: Clock
    purchases: Table[PurchaseId, Purchase]
    proofProbability*: UInt256

  PurchaseTimeout* = Timeout

const DefaultProofProbability = 100.u256

proc new*(
    _: type Purchasing, marketplace: AbstractMarketplace, clock: Clock
): Purchasing =
  Purchasing(
    marketplace: marketplace, clock: clock, proofProbability: DefaultProofProbability
  )

proc load*(purchasing: Purchasing) {.async.} =
  let marketplace = purchasing.marketplace
  let requestIds = await marketplace.myRequests()
  for requestId in requestIds:
    let purchase = Purchase.new(requestId, purchasing.marketplace, purchasing.clock)
    purchase.load()
    purchasing.purchases[purchase.id] = purchase

proc start*(purchasing: Purchasing) {.async.} =
  await purchasing.load()

proc stop*(purchasing: Purchasing) {.async: (raises: []).} =
  discard

proc populate*(
    purchasing: Purchasing, request: StorageRequest
): Future[?!StorageRequest] {.async: (raises: [CancelledError]).} =
  var populated = request
  if populated.ask.proofProbability == 0.u256:
    populated.ask.proofProbability = purchasing.proofProbability
  if populated.nonce == Nonce.default:
    var id = populated.nonce.toArray
    doAssert randomBytes(id) == 32
    populated.nonce = Nonce(id)
  try:
    populated.client = await purchasing.marketplace.getSigner()
  except MarketplaceError as error:
    return failure error
  success populated

proc purchase*(
    purchasing: Purchasing, request: StorageRequest
): Future[?!Purchase] {.async: (raises: [CancelledError]).} =
  let request = ?await purchasing.populate(request)
  let purchase = Purchase.new(request, purchasing.marketplace, purchasing.clock)
  purchase.start()
  purchasing.purchases[purchase.id] = purchase
  success purchase

func getPurchase*(purchasing: Purchasing, id: PurchaseId): ?Purchase =
  if purchasing.purchases.hasKey(id):
    some purchasing.purchases[id]
  else:
    none Purchase

func getPurchases*(purchasing: Purchasing): seq[PurchaseId] =
  var pIds: seq[PurchaseId] = @[]
  for key in purchasing.purchases.keys:
    pIds.add(key)
  return pIds
