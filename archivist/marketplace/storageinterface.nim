type StorageInterface* = ref object of RootObj

method available*(storage: StorageInterface): uint64 {.base, gcsafe, raises: [].} =
  raiseAssert "not implemented"
