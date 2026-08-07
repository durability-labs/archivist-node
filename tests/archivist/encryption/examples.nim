import pkg/chronos
import pkg/libp2p/stream/lpstream
import ../../examples

export examples.example

{.push raises: [].}

type LPStringStream = ref object of LPStream
  contents: string
  index: int

method readOnce*(
    stream: LPStringStream, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, LPStreamError]).} =
  let amount = min(nbytes, stream.contents.len - stream.index)
  if amount > 0:
    copyMem(pbytes, addr stream.contents[stream.index], amount)
  stream.index += amount
  if stream.index == stream.contents.len:
    stream.isEof = true
  amount

proc example*(_: type LPStream, contents = string.example): LPStream =
  let stream = LPStringStream(contents: contents)
  initStream(stream)
  stream
