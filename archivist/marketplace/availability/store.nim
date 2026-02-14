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
  let record = ?await get(availability.store, DatastoreKey, AvailabilityTerms)
  success(record.val)

proc save*(
    availability: AvailabilityStore, terms: AvailabilityTerms
): Future[?!void] {.async: (raises: [CancelledError]).} =
  ?await availability.store.tryPut(
    KVRecord[AvailabilityTerms].init(DatastoreKey, terms),
    maxRetries = 3,
    proc(
        failed: seq[KVRecord[AvailabilityTerms]]
    ): Future[?!seq[KVRecord[AvailabilityTerms]]] {.async: (raises: [CancelledError]).} =
      var record = ?await availability.store.get(failed[0].key, AvailabilityTerms)
      record.val = terms
      success @[record]
    ,
  )

  success()
