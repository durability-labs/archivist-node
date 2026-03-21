{.push raises: [].}

import std/tables

import pkg/chronos

type
  AsyncBarrier* = ref object
    count: int
    event: AsyncEvent

  KeyedBarrier*[K] = ref object
    barriers: Table[K, AsyncBarrier]

proc new*(T: type AsyncBarrier): AsyncBarrier =
  AsyncBarrier(event: newAsyncEvent())

proc count*(self: AsyncBarrier): int =
  self.count

proc enter*(self: AsyncBarrier) =
  self.count += 1
  self.event.clear()

proc leave*(self: AsyncBarrier) =
  self.count -= 1
  if self.count <= 0:
    self.count = 0
    self.event.fire()

proc drain*(
    self: AsyncBarrier
): Future[void] {.async: (raises: [CancelledError]).} =
  if self.count <= 0:
    return
  await self.event.wait()

proc new*[K](T: type KeyedBarrier[K]): KeyedBarrier[K] =
  KeyedBarrier[K]()

proc contains*[K](self: KeyedBarrier[K], key: K): bool =
  key in self.barriers

proc count*[K](self: KeyedBarrier[K], key: K): int =
  self.barriers.withValue(key, barrier):
    return barrier[].count
  return 0

proc enter*[K](self: KeyedBarrier[K], key: K) =
  self.barriers.withValue(key, barrier):
    barrier[].enter()
    return

  let barrier = AsyncBarrier.new()
  barrier.enter()
  self.barriers[key] = barrier

proc leave*[K](self: KeyedBarrier[K], key: K) =
  self.barriers.withValue(key, barrier):
    barrier[].leave()

    if barrier[].count <= 0:
      self.barriers.del(key)

proc drain*[K](
    self: KeyedBarrier[K], key: K
): Future[void] {.async: (raises: [CancelledError]).} =
  self.barriers.withValue(key, barrier):
    await barrier[].drain()
