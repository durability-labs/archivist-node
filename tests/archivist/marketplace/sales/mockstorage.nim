import pkg/chronos
import pkg/questionable/results
import pkg/libp2p/cid
import pkg/archivist/marketplace/storageinterface
import pkg/archivist/marketplace/abstractmarketplace
import ../../../examples

type MockStorage* = ref object of StorageInterface
  available: uint64
  storeSlotResult: ?!void
  proveSlotResult: ?!Groth16Proof
  updateSlotExpiryResult: ?!void
  slotFailedResult: ?!void
  proveSlotShouldHang*: bool
  storeSlotCalls: seq[(Cid, uint64, uint64, StorageTimestamp, bool)]
  proveSlotCalls: seq[(Cid, uint64, ProofChallenge)]
  updateSlotExpiryCalls: seq[(Cid, uint64, StorageTimestamp)]
  slotFailedCalls: seq[(Cid, uint64)]

proc new*(_: type MockStorage): MockStorage =
  MockStorage(
    storeSlotResult: success(),
    proveSlotResult: success(Groth16Proof.example),
    updateSlotExpiryResult: success(),
    slotFailedResult: success(),
  )

func `available=`*(mock: MockStorage, value: uint64) =
  mock.available = value

func `storeSlotResult=`*(mock: MockStorage, value: ?!void) =
  mock.storeSlotResult = value

func `proveSlotResult=`*(mock: MockStorage, value: ?!Groth16Proof) =
  mock.proveSlotResult = value

func `updateSlotExpiryResult=`*(mock: MockStorage, value: ?!void) =
  mock.updateSlotExpiryResult = value

func `slotFailedResult=`*(mock: MockStorage, value: ?!void) =
  mock.slotFailedResult = value

func storeSlotCalls*(
    mock: MockStorage
): seq[(Cid, uint64, uint64, StorageTimestamp, bool)] =
  mock.storeSlotCalls

func proveSlotCalls*(mock: MockStorage): seq[(Cid, uint64, ProofChallenge)] =
  mock.proveSlotCalls

func updateSlotExpiryCalls*(mock: MockStorage): seq[(Cid, uint64, StorageTimestamp)] =
  mock.updateSlotExpiryCalls

func slotFailedCalls*(mock: MockStorage): seq[(Cid, uint64)] =
  mock.slotFailedCalls

method available*(mock: MockStorage): uint64 {.gcsafe, raises: [].} =
  mock.available

method storeSlot*(
    mock: MockStorage,
    cid: Cid,
    slotIndex: uint64,
    slotSize: uint64,
    expiry: StorageTimestamp,
    repair: bool,
): Future[?!void] {.async: (raises: [CancelledError]).} =
  mock.storeSlotCalls.add((cid, slotIndex, slotSize, expiry, repair))
  mock.storeSlotResult

method proveSlot*(
    mock: MockStorage, cid: Cid, slotIndex: uint64, challenge: ProofChallenge
): Future[?!Groth16Proof] {.async: (raises: [CancelledError]).} =
  mock.proveSlotCalls.add((cid, slotIndex, challenge))
  if mock.proveSlotShouldHang:
    await sleepAsync(1.hours)
  mock.proveSlotResult

method updateSlotExpiry*(
    mock: MockStorage, cid: Cid, slotIndex: uint64, expiry: StorageTimestamp
): Future[?!void] {.async: (raises: [CancelledError]).} =
  mock.updateSlotExpiryCalls.add((cid, slotIndex, expiry))
  mock.updateSlotExpiryResult

method deleteSlot*(
    mock: MockStorage, cid: Cid, slotIndex: uint64
): Future[?!void] {.async: (raises: [CancelledError]).} =
  mock.slotFailedCalls.add((cid, slotIndex))
  mock.slotFailedResult
