import std/tables
import pkg/chronos
import pkg/libp2p/utils/semaphore

{.push raises: [].}

type TrackedSemaphore*[K] = ref object
  semas: Table[K, AsyncSemaphore]
  size: int

proc contains*[K](self: TrackedSemaphore[K], key: K): bool =
  key in self.semas

proc `count`*[K](self: TrackedSemaphore[K], key: K): int =
  self.semas.mgetOrPut(key, newAsyncSemaphore(self.size)).count

proc tryAcquire*[K](self: TrackedSemaphore[K], key: K): bool =
  self.semas.mgetOrPut(key, newAsyncSemaphore(self.size)).tryAcquire()

proc acquire*[K](
    self: TrackedSemaphore[K], key: K
): Future[void] {.async: (raises: [CancelledError], raw: true).} =
  return self.semas.mgetOrPut(key, newAsyncSemaphore(self.size)).acquire()

proc forceAcquire*[K](self: TrackedSemaphore[K], key: K) =
  self.semas.mgetOrPut(key, newAsyncSemaphore(self.size)).forceAcquire()

proc release*[K](self: TrackedSemaphore[K], key: K) =
  self.semas.withValue(key, sema):
    sema[].release

    if sema[].count == self.size:
      self.semas.del(key)

proc init*[K](self: type TrackedSemaphore[K], size: int): TrackedSemaphore[K] =
  TrackedSemaphore[K](size: size)
