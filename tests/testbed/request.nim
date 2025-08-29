import ./dataset

type Request* = ref object
  dataset: Dataset
  id: string

func init*(_: type Request, dataset: Dataset, id: string): Request =
  Request(dataset: dataset, id: id)

func dataset*(request: Request): Dataset =
  request.dataset

func id*(request: Request): string =
  request.id
