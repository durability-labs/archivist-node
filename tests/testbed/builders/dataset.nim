import std/sequtils
import std/random
import pkg/chronos
import pkg/questionable
import ../testbed
import ../dataset
import ../node
import ../http

type DatasetBuilder = ref object
  testbed: Testbed
  data: ?seq[byte]

func dataset*(testbed: Testbed): DatasetBuilder =
  DatasetBuilder(testbed: testbed)

proc upload*(builder: DatasetBuilder, node: Node): Future[Dataset] {.async.} =
  let data = builder.data |? newSeqWith(4*1024*1024, rand(byte))
  let url = node.apiUrl & "/data"
  let cid = await Http.post(url, data).readString()
  let dataset = Dataset.new()
  dataset.data = some data
  dataset.cid = some cid
  dataset
