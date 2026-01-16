import pkg/chronos
import pkg/questionable/results
import pkg/libp2p/cid
import pkg/archivist/marketplace/storageinterface
import pkg/archivist/marketplace/abstractmarketplace
import pkg/archivist/clock
import ../../../examples

type MockStorage* = ref object of StorageInterface
  available: uint64
  storeSlotResult: ?!void
  proveSlotResult: ?!Groth16Proof
  updateSlotExpiryResult: ?!void
  storeSlotCalls: seq[StoreSlotAsk]
  proveSlotCalls: seq[(Cid, uint64, ProofChallenge)]
  updateSlotExpiryCalls: seq[(Cid, uint64, SecondsSince1970)]

proc new*(_: type MockStorage): MockStorage =
  MockStorage(
    storeSlotResult: success(),
    proveSlotResult: success(Groth16Proof.example),
    updateSlotExpiryResult: success(),
  )

func `available=`*(mock: MockStorage, value: uint64) =
  mock.available = value

func `storeSlotResult=`*(mock: MockStorage, value: ?!void) =
  mock.storeSlotResult = value

func `proveSlotResult=`*(mock: MockStorage, value: ?!Groth16Proof) =
  mock.proveSlotResult = value

func `updateSlotExpiryResult=`*(mock: MockStorage, value: ?!void) =
  mock.updateSlotExpiryResult = value

func storeSlotCalls*(mock: MockStorage): seq[StoreSlotAsk] =
  mock.storeSlotCalls

func proveSlotCalls*(mock: MockStorage): seq[(Cid, uint64, ProofChallenge)] =
  mock.proveSlotCalls

func updateSlotExpiryCalls*(mock: MockStorage): seq[(Cid, uint64, SecondsSince1970)] =
  mock.updateSlotExpiryCalls

method available*(mock: MockStorage): uint64 {.gcsafe, raises: [].} =
  mock.available

method storeSlot*(
    mock: MockStorage, storeAsk: StoreSlotAsk
): Future[?!void] {.async: (raises: [CancelledError]).} =
  mock.storeSlotCalls.add(storeAsk)
  mock.storeSlotResult

method proveSlot*(
    mock: MockStorage, cid: Cid, slotIndex: uint64, challenge: ProofChallenge
): Future[?!Groth16Proof] {.async: (raises: [CancelledError]).} =
  mock.proveSlotCalls.add((cid, slotIndex, challenge))
  mock.proveSlotResult

method updateSlotExpiry*(
    mock: MockStorage, cid: Cid, slotIndex: uint64, expiry: SecondsSince1970
): Future[?!void] {.async: (raises: [CancelledError]).} =
  mock.updateSlotExpiryCalls.add((cid, slotIndex, expiry))
  mock.updateSlotExpiryResult
