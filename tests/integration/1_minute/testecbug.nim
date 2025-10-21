import std/json
import pkg/asynctest/chronos/unittest2
import ../../testbed

suite "Bug 821 - node crashes during erasure coding":
  # https://github.com/codex-storage/nim-codex/issues/821

  var testbed: Testbed
  var node: Node

  setup:
    testbed = await Testbed.start()
    discard await testbed.hardhat.start()
    node = await testbed.node.persistence.start()

  teardown:
    await testbed.stop()

  test "should be able to create storage request and download dataset":
    let request = await testbed.request.submit(node)
    let purchase = await testbed.api(node).getPurchase(request.id)
    let manifestCid = purchase["request"]["content"]["cid"].getStr()
    let downloaded = await testbed.api(node).download(manifestCid)
    check downloaded == request.dataset.data
