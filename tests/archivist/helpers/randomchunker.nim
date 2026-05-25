import pkg/chronos

import pkg/archivist/chunker
import pkg/archivist/rng

export chunker

type RandomChunker* = Chunker

proc new*(
    T: type RandomChunker,
    rng: Rng,
    chunkSize: int | NBytes,
    size: int | NBytes,
    pad = false,
): RandomChunker =
  ## Create a chunker that produces random data
  ##

  let
    size = size.int
    chunkSize = chunkSize.NBytes

  var consumed = 0
  proc reader(
      data: ChunkBuffer, len: int
  ): Future[?!int] {.async: (raises: [CancelledError]), gcsafe.} =
    if consumed >= size:
      return success 0

    let read =
      if pad:
        len
      else:
        min(len, size - consumed)

    var bytes = newSeq[byte](read)
    rng[].generate(bytes)
    if read > 0:
      copyMem(data, addr bytes[0], read)

    consumed += read
    success read

  Chunker.new(reader = reader, pad = pad, chunkSize = chunkSize)
