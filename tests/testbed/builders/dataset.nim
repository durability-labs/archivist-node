import std/sequtils
import std/random
import pkg/chronos
import pkg/questionable
import ../network/node
import ../testbed
import ../dataset
import ./api

type DatasetBuilder = ref object
  testbed: Testbed
  data: ?seq[byte]

func dataset*(testbed: Testbed): DatasetBuilder =
  DatasetBuilder(testbed: testbed)

func data*(builder: DatasetBuilder, data: seq[byte]): DatasetBuilder =
  builder.data = some data
  builder

func data*(builder: DatasetBuilder, data: string): DatasetBuilder =
  builder.data(cast[seq[byte]](data))

proc upload*(builder: DatasetBuilder, node: Node): Future[Dataset] {.async.} =
  let data = builder.data |? newSeqWith(4*1024*1024, rand(byte))
  let cid = await builder.testbed.api(node).upload(data)
  let dataset = Dataset.new()
  dataset.data = data
  dataset.cid = some cid
  dataset
