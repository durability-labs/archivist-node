import pkg/questionable

type Dataset* = ref object
  data: ?seq[byte]
  cid: ?string
  requestIds: seq[string]

func data*(dataset: Dataset): var Option[seq[byte]] =
  dataset.data

func cid*(dataset: Dataset): ?string =
  dataset.cid

func `cid=`*(dataset: Dataset, cid: ?string) =
  dataset.cid = cid

func requestIds*(dataset: Dataset): seq[string] =
  dataset.requestIds

func addRequestId*(dataset: Dataset, requestId: string) =
  dataset.requestIds.add(requestId)
