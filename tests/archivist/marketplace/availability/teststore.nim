import pkg/questionable/results
import pkg/datastore/typedds
import archivist/marketplace/availability/store
import archivist/marketplace/availability/terms
import ../../../asynctest
import ../../../helpers/templeveldb
import ./examples

suite "availability store":
  var store: AvailabilityStore
  var database: TempLevelDb

  setup:
    database = TempLevelDb.new()
    let datastore = TypedDatastore.init(database.newDb())
    store = AvailabilityStore.new(datastore)

  teardown:
    await database.destroyDb()

  test "cannot load when there's are no terms saved":
    let loaded = await store.load()
    check loaded.isFailure

  test "saves terms":
    let terms = AvailabilityTerms.example
    check isSuccess await store.save(terms)

  test "loads terms that were previously saved":
    let terms = AvailabilityTerms.example
    discard await store.save(terms)
    check (await store.load()) == success terms

  test "overwrites previously saved terms":
    let terms1, terms2 = AvailabilityTerms.example
    discard await store.save(terms1)
    discard await store.save(terms2)
    check (await store.load()) == success terms2
