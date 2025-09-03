import pkg/questionable

type Dataset* = ref object
  data: seq[byte]
  cid: ?string

func data*(dataset: Dataset): seq[byte] =
  dataset.data

func `data=`*(dataset: Dataset, data: seq[byte]) =
  dataset.data = data

func cid*(dataset: Dataset): ?string =
  dataset.cid

func `cid=`*(dataset: Dataset, cid: ?string) =
  dataset.cid = cid
