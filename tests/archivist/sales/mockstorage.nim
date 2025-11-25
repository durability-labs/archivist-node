import pkg/archivist/marketplace/storageinterface

type MockStorage* = ref object of StorageInterface
  available: uint64

func `available=`*(mock: MockStorage, value: uint64) =
  mock.available = value

method available*(mock: MockStorage): uint64 {.gcsafe, raises: [].} =
  mock.available
