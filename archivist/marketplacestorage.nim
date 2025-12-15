import ./marketplace
import ./stores/repostore

type MarketplaceStorage* = ref object of marketplace.StorageInterface
  repoStore: RepoStore

func new*(_: type MarketplaceStorage, repoStore: RepoStore): MarketplaceStorage =
  MarketplaceStorage(repoStore: repoStore)

method available*(storage: MarketplaceStorage): uint64 {.gcsafe, raises: [].} =
  storage.repoStore.available.uint64
