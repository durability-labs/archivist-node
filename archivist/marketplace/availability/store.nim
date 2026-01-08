import pkg/chronos
import pkg/questionable/results
import pkg/kvstore
import ../../stores/keyutils
import ./terms
import ./encoding

type AvailabilityStore* = ref object
  store: KVStore

const DatastoreKey = (
  (ArchivistMetaKey / "sales").flatMap(
    proc(k: Key): ?!Key =
      k / "availability"
  )
).tryGet

func new*(_: type AvailabilityStore, store: KVStore): AvailabilityStore =
  AvailabilityStore(store: store)

proc load*(
    availability: AvailabilityStore
): Future[?!AvailabilityTerms] {.async: (raises: [CancelledError]).} =
  without record =? await get[AvailabilityTerms](availability.store, DatastoreKey), err:
    return failure(err)
  success(record.val)

proc save*(
    availability: AvailabilityStore, terms: AvailabilityTerms
): Future[?!void] {.async: (raises: [CancelledError]).} =
  let encoded = encode(terms)
  ?await availability.store.put(DatastoreKey, encoded)
  success()
