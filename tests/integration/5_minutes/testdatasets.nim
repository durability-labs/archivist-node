import std/json
import std/sequtils
import std/strutils
import pkg/asynctest/chronos/unittest2
import pkg/questionable
import ../../testbed

suite "Node datasets":
  var testbed: Testbed
  var node: Node

  setup:
    testbed = await Testbed.start()
    node = await testbed.node.start()

  teardown:
    await testbed.stop()

  test "node returns used and available space":
    let before = await testbed.api(node).getSpace()
    let dataset = await testbed.dataset.upload(node)
    let after = await testbed.api(node).getSpace()
    let quotaMaxBefore = before["quotaMaxBytes"].getInt()
    let quotaMaxAfter = after["quotaMaxBytes"].getInt()
    let quotaUsedBefore = before["quotaUsedBytes"].getInt()
    let quotaUsedAfter = after["quotaUsedBytes"].getInt()
    let totalBlocksBefore = before["totalBlocks"].getInt()
    let totalBlocksAfter = after["totalBlocks"].getInt()
    check quotaMaxAfter == quotaMaxBefore
    check totalBlocksAfter > totalBlocksBefore
    check quotaUsedAfter >= quotaUsedBefore + dataset.data.len

  test "node returns list of local datasets":
    let dataset1 = await testbed.dataset.upload(node)
    let dataset2 = await testbed.dataset.upload(node)
    let data = await testbed.api(node).getData()
    let cids = data["content"].mapIt(it["cid"])
    check cids.len == 2
    check %(!dataset1.cid) in cids
    check %(!dataset2.cid) in cids

  test "node can delete a dataset":
    let dataset = await testbed.dataset.upload(node)
    await testbed.api(node).delete(!dataset.cid)
    try:
      discard await testbed.api(node).download(!dataset.cid, network = false)
      fail()
    except HttpError as error:
      check "404" in error.msg

  test "node allows deletion of absent dataset":
    let cid = "zb2rhe5P4gXftAwvA4eXQ5HJwsER2owDyS9sKaQRRVQPn93bA"
    await testbed.api(node).delete(cid)
