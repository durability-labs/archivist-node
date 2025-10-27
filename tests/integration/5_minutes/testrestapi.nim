import std/json
import pkg/asynctest/chronos/unittest2
import ../../testbed

suite "REST API":
  var testbed: Testbed
  var node1, node2: Node

  setup:
    testbed = await Testbed.start()
    node1 = await testbed.node.start()
    node2 = await testbed.node.start()

  teardown:
    await testbed.stop()

  test "nodes return their peer information":
    let info1 = await testbed.api(node1).getDebugInfo()
    let info2 = await testbed.api(node2).getDebugInfo()
    check info1["id"] != info2["id"]
    check info1["spr"] != info2["spr"]
    check info1["announceAddresses"] != info2["announceAddresses"]

  test "nodes can set chronicles log level":
    await testbed.api(node1).setLogLevel("DEBUG;TRACE:archivist")
