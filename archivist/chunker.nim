## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# TODO: This is super inneficient and needs a rewrite, but it'll do for now

{.push raises: [].}

import pkg/questionable
import pkg/questionable/results
import pkg/chronos
import pkg/libp2p except shuffle

import ./blocktype
import ./logutils

export blocktype

const DefaultChunkSize* = DefaultBlockSize

type
  # default reader type
  ChunkBuffer* = ptr UncheckedArray[byte]
  Reader* = proc(data: ChunkBuffer, len: int): Future[?!int] {.
    gcsafe, async: (raises: [CancelledError])
  .}

  # Reader that splits input data into fixed-size chunks
  Chunker* = ref object
    reader*: Reader # Procedure called to actually read the data
    offset*: int # Bytes read so far (position in the stream)
    chunkSize*: NBytes # Size of each chunk
    pad*: bool # Pad last chunk to chunkSize?

  FileChunker* = Chunker
  LPStreamChunker* = Chunker

proc getBytes*(c: Chunker): Future[?!seq[byte]] {.async: (raises: [CancelledError]).} =
  ## returns a chunk of bytes from
  ## the instantiated chunker
  ##

  var buff = newSeq[byte](c.chunkSize.int)
  let read = ?await c.reader(cast[ChunkBuffer](addr buff[0]), buff.len)

  if read <= 0:
    return success(newSeq[byte](0))

  c.offset += read

  if not c.pad and buff.len > read:
    buff.setLen(read)

  success move buff

proc new*(
    T: type Chunker, reader: Reader, chunkSize = DefaultChunkSize, pad = true
): Chunker =
  ## create a new Chunker instance
  ##
  Chunker(reader: reader, offset: 0, chunkSize: chunkSize, pad: pad)

proc new*(
    T: type LPStreamChunker, stream: LPStream, chunkSize = DefaultChunkSize, pad = true
): LPStreamChunker =
  ## create the default File chunker
  ##

  proc reader(
      data: ChunkBuffer, len: int
  ): Future[?!int] {.gcsafe, async: (raises: [CancelledError]).} =
    var res = 0
    try:
      while res < len:
        res += await stream.readOnce(addr data[res], len - res)
    except LPStreamEOFError:
      discard # EOF reached, return bytes read so far
    except LPStreamError as exc:
      return failure(exc)

    return success res

  LPStreamChunker.new(reader = reader, chunkSize = chunkSize, pad = pad)

proc new*(
    T: type FileChunker, file: File, chunkSize = DefaultChunkSize, pad = true
): FileChunker =
  ## create the default File chunker
  ##

  proc reader(
      data: ChunkBuffer, len: int
  ): Future[?!int] {.gcsafe, async: (raises: [CancelledError]).} =
    var total = 0
    while total < len:
      let res = ?catch(file.readBuffer(addr data[total], len - total))
      if res <= 0:
        break

      total += res

    return success total

  FileChunker.new(reader = reader, chunkSize = chunkSize, pad = pad)
