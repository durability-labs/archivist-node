import ./dataset

type Request* = ref object
  dataset: Dataset
  id: string
  duration: int
  expiry: int

func init*(
  _: type Request,
  dataset: Dataset,
  id: string,
  duration: int,
  expiry: int
): Request =
  Request(dataset: dataset, id: id, duration: duration, expiry: expiry)

func dataset*(request: Request): Dataset =
  request.dataset

func id*(request: Request): string =
  request.id

func duration*(request: Request): int =
  request.duration

func expiry*(request: Request): int =
  request.expiry
