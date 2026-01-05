import std/tables
import std/times

import pkg/libp2p
import pkg/chronos
import pkg/archivist/archivisttypes
import pkg/archivist/chunker
import pkg/archivist/stores

import ../../asynctest

type CountingStore* = ref object of NetworkStore
  lookups*: Table[Cid, int]

proc new*(
    T: type CountingStore, engine: BlockExcEngine, localStore: BlockStore
): CountingStore =
  # XXX this works cause NetworkStore.new is trivial
  result = CountingStore(engine: engine, localStore: localStore)

method getBlock*(
    self: CountingStore, address: BlockAddress
): Future[?!Block] {.async: (raises: [CancelledError]).} =
  self.lookups.mgetOrPut(address.cid, 0).inc
  await procCall getBlock(NetworkStore(self), address)

proc toTimesDuration*(d: chronos.Duration): times.Duration =
  initDuration(seconds = d.seconds)

proc drain*(
    stream: LPStream | Result[lpstream.LPStream, ref CatchableError]
): Future[seq[byte]] {.async.} =
  let stream =
    when typeof(stream) is Result[lpstream.LPStream, ref CatchableError]:
      stream.tryGet()
    else:
      stream

  defer:
    await stream.close()

  var data: seq[byte]
  while not stream.atEof:
    var
      buf = newSeq[byte](DefaultBlockSize.int)
      res = await stream.readOnce(addr buf[0], DefaultBlockSize.int)
    check res <= DefaultBlockSize.int
    buf.setLen(res)
    data &= buf

  data

proc pipeChunker*(stream: BufferStream, chunker: Chunker) {.async.} =
  try:
    while (let chunk = await chunker.getBytes(); chunk.len > 0):
      await stream.pushData(chunk)
  finally:
    await stream.pushEof()
    await stream.close()
