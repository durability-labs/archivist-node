import std/strutils
import std/json
import pkg/asynctest/chronos/unittest2
import pkg/questionable
import pkg/chronos/apps/http/httpclient
import ../../testbed

suite "Uploads and downloads":

  var testbed: Testbed
  var node1, node2: Node

  setup:
    testbed = await Testbed.start()
    node1 = await testbed.node.start()
    node2 = await testbed.node.start()

  teardown:
    await testbed.stop()

  test "node allows local file downloads":
    let dataset1 = await testbed.dataset.upload(node1)
    let dataset2 = await testbed.dataset.upload(node2)
    let download1 = await testbed.api(node1).download(!dataset1.cid, network = false)
    let download2 = await testbed.api(node2).download(!dataset2.cid, network = false)
    check download1 == dataset1.data
    check download2 == dataset2.data

  test "node allows remote file downloads":
    let dataset1 = await testbed.dataset.upload(node1)
    let dataset2 = await testbed.dataset.upload(node2)
    let download1 = await testbed.api(node2).download(!dataset1.cid)
    let download2 = await testbed.api(node1).download(!dataset2.cid)
    check download1 == dataset1.data
    check download2 == dataset2.data

  test "node fails to retrieve non-existing local file":
    let dataset = await testbed.dataset.upload(node1)
    try:
      discard await testbed.api(node2).download(!dataset.cid, network = false)
      fail()
    except HttpError as error:
      check "404" in error.msg

  let exampleData = "some file contents"
  let exampleDataManifest = %*{
    "treeCid": "zDzSvJTezk7bJNQqFq8k1iHXY84psNuUfZVusA5bBQQUSuyzDSVL",
    "datasetSize": 18,
    "blockSize": 65536,
    "protected": false,
    "filename": nil,
    "mimetype": nil
  }

  test "node allows downloading only manifest":
    let dataset = await testbed.dataset.data(exampleData).upload(node1)
    let manifest = await testbed.api(node1).downloadManifest(!dataset.cid)
    check manifest{"cid"} == %(!dataset.cid)
    check manifest{"manifest"} == exampleDataManifest

  test "node allows downloading content without streaming":
    let dataset = await testbed.dataset.data(exampleData).upload(node1)
    let manifest = await testbed.api(node2).downloadInBackground(!dataset.cid)
    check manifest{"cid"} == %(!dataset.cid)
    check manifest{"manifest"} == exampleDataManifest
    await sleepAsync(1.seconds) # allow for the data to be transfered
    let download = await testbed.api(node2).download(!dataset.cid, network = false)
    check download == dataset.data

  test "nodes reliably transfer datasets between themselves":
    proc testTransfer(a, b: Node) {.async.} =
      let dataset = await testbed.dataset.upload(a)
      let download = await testbed.api(b).download(!dataset.cid)
      check download == dataset.data
    for _ in 0..10:
      await testTransfer(node1, node2)
      await testTransfer(node2, node1)

  test "node sets file name and mime type for downloads":
    let mimetype = "application/octet-stream"
    let filename = "example.bin"
    let dataset = await testbed
      .dataset
      .mimetype(mimetype)
      .filename(filename)
      .upload(node1)
    let response = await testbed.api(node1).raw.download(!dataset.cid)
    let disposition = "attachment; filename=\"" & filename & "\""
    check ("content-type", mimetype) in response.headers
    check ("content-disposition", disposition) in response.headers
    await response.close()

  test "node accepts content disposition header without filename":
    let headers = @{"Content-Disposition": "attachment"}
    discard await testbed.dataset.upload(node1, headers = headers)

  test "node does not crash when the download stream is closed too soon":
    let dataset = await testbed.dataset.upload(node1)
    let response = await testbed.api(node1).raw.download(!dataset.cid)
    let reader = HttpClientResponseRef(response).getBodyReader()
    # read a few bytes to ensure that we're receiving data
    check (await reader.read(4)) == dataset.data[0..<4]
    # close the stream at a low level, to ensure that it isn't closed nicely
    HttpClientResponseRef(response).connection.reader.tsource.close()
    # check that the node hasn't crashed
    check (await testbed.api(node1).download(!dataset.cid)) == dataset.data
