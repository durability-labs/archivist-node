import ./dataset

type Request* = ref object
  dataset: Dataset
  id: string
  duration: uint64
  expiry: uint64

func init*(
  _: type Request,
  dataset: Dataset,
  id: string,
  duration: uint64,
  expiry: uint64
): Request =
  Request(dataset: dataset, id: id, duration: duration, expiry: expiry)

func dataset*(request: Request): Dataset =
  request.dataset

func id*(request: Request): string =
  request.id

func duration*(request: Request): uint64 =
  request.duration

func expiry*(request: Request): uint64 =
  request.expiry
