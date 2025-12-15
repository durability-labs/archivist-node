import pkg/chronos
import pkg/questionable/results
import pkg/datastore/typedds
import ../../stores/keyutils
import ./terms
import ./encoding

type AvailabilityStore* = ref object
  store: TypedDatastore

const DatastoreKey = !(!(ArchivistMetaKey / "sales") / "availability")

func new*(_: type AvailabilityStore, store: TypedDatastore): AvailabilityStore =
  AvailabilityStore(store: store)

proc load*(
    availability: AvailabilityStore
): Future[?!AvailabilityTerms] {.async: (raises: [CancelledError]).} =
  await get[AvailabilityTerms](availability.store, DataStoreKey)

proc save*(
    availability: AvailabilityStore, terms: AvailabilityTerms
): Future[?!void] {.async: (raises: [CancelledError]).} =
  await availability.store.put(DataStoreKey, terms)
