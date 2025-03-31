import pkg/chronos
import pkg/questionable/results
import pkg/libp2p/cid
import ./contracts/proofs
import ./abstractmarketplace

export abstractmarketplace.ProofChallenge
export proofs.Groth16Proof
export proofs.G1Point
export proofs.G2Point
export proofs.Fp2Element

type StorageInterface* = ref object of RootObj

method available*(storage: StorageInterface): uint64 {.base, gcsafe, raises: [].} =
  raiseAssert "not implemented"

method storeSlot*(
    storage: StorageInterface,
    cid: Cid,
    slotIndex: uint64,
    slotSize: uint64,
    expiry: StorageTimestamp,
    repair: bool,
): Future[?!void] {.base, async: (raises: [CancelledError]).} =
  raiseAssert "not implemented"

method proveSlot*(
    storage: StorageInterface, cid: Cid, slotIndex: uint64, challenge: ProofChallenge
): Future[?!Groth16Proof] {.base, async: (raises: [CancelledError]).} =
  raiseAssert "not implemented"

method updateSlotExpiry*(
    storage: StorageInterface, cid: Cid, slotIndex: uint64, expiry: StorageTimestamp
): Future[?!void] {.base, async: (raises: [CancelledError]).} =
  raiseAssert "not implemented"
