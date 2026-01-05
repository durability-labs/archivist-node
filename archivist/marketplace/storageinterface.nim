import pkg/chronos
import pkg/questionable/results
import pkg/libp2p/cid
import ../clock
import ../contracts/proofs
import ./abstractmarketplace

type StorageInterface* = ref object of RootObj

method available*(storage: StorageInterface): uint64 {.base, gcsafe, raises: [].} =
  raiseAssert "not implemented"

method storeSlot*(
    storage: StorageInterface,
    cid: Cid,
    slotIndex: uint64,
    expiry: SecondsSince1970,
    repair: bool,
): Future[?!void] {.base, async: (raises: [CancelledError]).} =
  raiseAssert "not implemented"

method proveSlot*(
    storage: StorageInterface, cid: Cid, slotIndex: uint64, challenge: ProofChallenge
): Future[?!Groth16Proof] {.base, async: (raises: [CancelledError]).} =
  raiseAssert "not implemented"

method updateSlotExpiry*(
    storage: StorageInterface, cid: Cid, slotIndex: uint64, expiry: SecondsSince1970
): Future[?!void] {.base, async: (raises: [CancelledError]).} =
  raiseAssert "not implemented"
