import pkg/chronos
import ./marketplace
import ./node
import ./stores/repostore

type MarketplaceStorage* = ref object of marketplace.StorageInterface
  node: ArchivistNodeRef
  repoStore: RepoStore

func new*(
    _: type MarketplaceStorage, node: ArchivistNodeRef, repoStore: RepoStore
): MarketplaceStorage =
  MarketplaceStorage(node: node, repoStore: repoStore)

method available*(storage: MarketplaceStorage): uint64 {.gcsafe, raises: [].} =
  storage.repoStore.available.uint64

method storeSlot*(
    storage: MarketplaceStorage,
    cid: Cid,
    slotIndex: uint64,
    slotSize: uint64,
    expiry: StorageTimestamp,
    repair: bool,
): Future[?!void] {.async: (raises: [CancelledError]).} =
  await storage.node.storeSlot(
    cid, slotIndex, slotSize, expiry.toSecondsSince1970, repair
  )

method proveSlot*(
    storage: MarketplaceStorage, cid: Cid, slotIndex: uint64, challenge: ProofChallenge
): Future[?!Groth16Proof] {.async: (raises: [CancelledError]).} =
  await storage.node.proveSlot(cid, slotIndex, challenge)

method updateSlotExpiry*(
    storage: MarketplaceStorage, cid: Cid, slotIndex: uint64, expiry: StorageTimestamp
): Future[?!void] {.async: (raises: [CancelledError]).} =
  # TODO: update only the slot expiry, not the expiry of the entiry dataset
  await storage.node.updateExpiry(cid, expiry.toSecondsSince1970)
