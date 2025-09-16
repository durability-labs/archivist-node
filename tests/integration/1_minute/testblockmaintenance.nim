import std/strutils
import pkg/asynctest/chronos/unittest2
import pkg/questionable
import ../../testbed

suite "Block maintenance":

  var testbed: Testbed
  var node: Node

  setup:
    testbed = await Testbed.start()
    node = await testbed
      .node
      .blockTtl(5)
      .blockMaintenanceInterval(1)
      .start()

  teardown:
    await testbed.stop()

  test "node retains file that hasn't expired yet":
    let dataset = await testbed.dataset.upload(node)
    await sleepAsync(2.seconds)
    discard await testbed.api(node).download(!dataset.cid, network = false)

  test "node deletes expired file":
    let dataset = await testbed.dataset.upload(node)
    await sleepAsync(10.seconds)
    try:
      discard await testbed.api(node).download(!dataset.cid, network = false)
      fail()
    except HttpError as error:
      check "404" in error.msg
