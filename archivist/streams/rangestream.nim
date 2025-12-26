## Copyright (c) 2025 Archivist Authors
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## RangeStream - A stream wrapper that provides access to a byte range
## of an underlying SeekableStream. Used for HTTP Range request support.

{.push raises: [].}

import pkg/chronos
import pkg/libp2p/stream/lpstream

import ./seekablestream
import ../logutils

export seekablestream

logScope:
  topics = "archivist rangestream"

const RangeStreamTrackerName* = "RangeStream"

type
  RangeStream* = ref object of LPStream
    source*: SeekableStream
    rangeStart*: int      # First byte of the range (inclusive)
    rangeEnd*: int        # Last byte of the range (inclusive)
    bytesRemaining*: int  # Bytes left to read in this range

method initStream*(s: RangeStream) =
  if s.objName.len == 0:
    s.objName = RangeStreamTrackerName
  procCall LPStream(s).initStream()

proc new*(
    T: type RangeStream,
    source: SeekableStream,
    rangeStart: int,
    rangeEnd: int
): RangeStream =
  ## Create a RangeStream that reads bytes [rangeStart, rangeEnd] from source.
  ## Both bounds are inclusive (per HTTP Range semantics).
  ##
  let rangeLen = rangeEnd - rangeStart + 1
  result = RangeStream(
    source: source,
    rangeStart: rangeStart,
    rangeEnd: rangeEnd,
    bytesRemaining: rangeLen
  )
  # Seek the underlying stream to the start of our range
  source.setPos(rangeStart)
  result.initStream()

proc rangeLength*(self: RangeStream): int =
  ## Total length of this range
  self.rangeEnd - self.rangeStart + 1

method atEof*(self: RangeStream): bool =
  self.bytesRemaining <= 0 or self.source.atEof

method readOnce*(
    self: RangeStream, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, LPStreamError]).} =
  ## Read up to nbytes, but never more than bytesRemaining in our range.
  ##
  if self.atEof:
    raise newLPStreamEOFError()

  # Don't read past our range boundary
  let toRead = min(nbytes, self.bytesRemaining)
  let bytesRead = await self.source.readOnce(pbytes, toRead)

  self.bytesRemaining -= bytesRead
  return bytesRead

method closeImpl*(self: RangeStream) {.async: (raises: []).} =
  trace "Closing RangeStream"
  await self.source.close()
  await procCall LPStream(self).closeImpl()
