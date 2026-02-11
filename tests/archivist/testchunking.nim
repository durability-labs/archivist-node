import pkg/stew/byteutils
import pkg/questionable/results
import pkg/archivist/chunker
import pkg/archivist/logutils
import pkg/chronos

import ../asynctest
import ./helpers

# Trying to use a CancelledError or LPStreamError value for toRaise
# will produce a compilation error;
# Error: only a 'ref object' can be raised
# This is because they are not ref object but plain object.
# CancelledError* = object of FutureError
# LPStreamError* = object of LPError

type CrashingStreamWrapper* = ref object of LPStream
  toRaise*: proc(): void {.gcsafe, raises: [CancelledError, LPStreamError].}

method readOnce*(
    self: CrashingStreamWrapper, pbytes: pointer, nbytes: int
): Future[int] {.gcsafe, async: (raises: [CancelledError, LPStreamError]).} =
  self.toRaise()

asyncchecksuite "Chunking":
  test "should return proper size chunks":
    var offset = 0
    let contents = [1.byte, 2, 3, 4, 5, 6, 7, 8, 9, 0]
    proc reader(
        data: ChunkBuffer, len: int
    ): Future[?!int] {.gcsafe, async: (raises: [CancelledError]).} =
      let read = min(contents.len - offset, len)
      if read == 0:
        return success 0

      copyMem(data, unsafeAddr contents[offset], read)
      offset += read
      return success read

    let chunker = Chunker.new(reader = reader, chunkSize = 2'nb)

    check:
      (await chunker.getBytes()).tryGet() == [1.byte, 2]
      (await chunker.getBytes()).tryGet() == [3.byte, 4]
      (await chunker.getBytes()).tryGet() == [5.byte, 6]
      (await chunker.getBytes()).tryGet() == [7.byte, 8]
      (await chunker.getBytes()).tryGet() == [9.byte, 0]
      (await chunker.getBytes()).tryGet() == []
      chunker.offset == offset

  test "should chunk LPStream":
    let stream = BufferStream.new()
    let chunker = LPStreamChunker.new(stream = stream, chunkSize = 2'nb)

    proc writer() {.async.} =
      for d in [@[1.byte, 2, 3, 4], @[5.byte, 6, 7, 8], @[9.byte, 0]]:
        await stream.pushData(d)
      await stream.pushEof()
      await stream.close()

    let writerFut = writer()
    check:
      (await chunker.getBytes()).tryGet() == [1.byte, 2]
      (await chunker.getBytes()).tryGet() == [3.byte, 4]
      (await chunker.getBytes()).tryGet() == [5.byte, 6]
      (await chunker.getBytes()).tryGet() == [7.byte, 8]
      (await chunker.getBytes()).tryGet() == [9.byte, 0]
      (await chunker.getBytes()).tryGet() == []
      chunker.offset == 10

    await writerFut

  test "should chunk file":
    let
      path = currentSourcePath()
      file = open(path)
      fileChunker = FileChunker.new(file = file, chunkSize = 256'nb, pad = false)

    var data: seq[byte]
    while true:
      let buff = (await fileChunker.getBytes()).tryGet()
      if buff.len <= 0:
        break

      check buff.len <= fileChunker.chunkSize.int
      data.add(buff)

    check:
      string.fromBytes(data) == readFile(path)
      fileChunker.offset == data.len

  proc raiseStreamException(exc: ref CancelledError | ref LPStreamError) {.async.} =
    let stream = CrashingStreamWrapper.new()
    let chunker = LPStreamChunker.new(stream = stream, chunkSize = 2'nb)

    stream.toRaise = proc(): void {.raises: [CancelledError, LPStreamError].} =
      raise exc
    discard (await chunker.getBytes())

  test "stream should forward LPStreamError":
    let stream = CrashingStreamWrapper.new()
    let chunker = LPStreamChunker.new(stream = stream, chunkSize = 2'nb)

    stream.toRaise = proc(): void {.raises: [CancelledError, LPStreamError].} =
      raise newException(LPStreamError, "test error")

    let res = await chunker.getBytes()
    check res.isErr
    check res.error of LPStreamError

  test "stream should catch LPStreamEOFError":
    let stream = CrashingStreamWrapper.new()
    let chunker = LPStreamChunker.new(stream = stream, chunkSize = 2'nb)

    stream.toRaise = proc(): void {.raises: [CancelledError, LPStreamError].} =
      raise newException(LPStreamEOFError, "test error")

    check (await chunker.getBytes()).tryGet() == []

  test "stream should forward CancelledError":
    expect CancelledError:
      await raiseStreamException(newException(CancelledError, "test error"))
