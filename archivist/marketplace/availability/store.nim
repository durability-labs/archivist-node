import pkg/chronos
import pkg/questionable/results
import pkg/kvstore
import ../../stores/keyutils
import ./terms
import ./encoding

type AvailabilityStore* = ref object
  store: KVStore

const DatastoreKey = !(!(ArchivistMetaKey / "sales") / "availability")

func new*(_: type AvailabilityStore, store: KVStore): AvailabilityStore =
  AvailabilityStore(store: store)

proc load*(
    availability: AvailabilityStore
): Future[?!AvailabilityTerms] {.async: (raises: [CancelledError]).} =
  let record = ?await get(availability.store, DataStoreKey, AvailabilityTerms)
  success(record.val)

proc save*(
    availability: AvailabilityStore, terms: AvailabilityTerms
): Future[?!void] {.async: (raises: [CancelledError]).} =
  await availability.store.put(DataStoreKey, terms)
