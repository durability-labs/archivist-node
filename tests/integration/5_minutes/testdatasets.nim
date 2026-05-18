import std/json
import std/sequtils
import std/strutils
import pkg/asynctest/chronos/unittest2
import pkg/libp2p/cid
import pkg/libp2p/multihash
import pkg/questionable
import pkg/archivist/archivisttypes
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

  test "used and available space is preserved after a restart":
    discard await testbed.dataset.upload(node)
    let before = await testbed.api(node).getSpace()
    await node.restart()
    let after = await testbed.api(node).getSpace()
    check before == after

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

  test "node returns 404 when deleting absent dataset":
    let
      mhash = MultiHash.digest("sha2-256", @[0'u8]).tryGet()
      cid = Cid.init(CIDv1, ManifestCodec, mhash).tryGet()
    try:
      await testbed.api(node).delete($cid)
      fail()
    except HttpError as error:
      check "404" in error.msg

  test "cannot upload dataset that would exceed quota":
    let smallNode = await testbed.node.storageQuota(1024 * 1024).start()

    try:
      discard await testbed.dataset.data(2 * 1024 * 1024).upload(smallNode)
      fail()
    except HttpError as error:
      check "413" in error.msg

  test "node can return status of a dataset":
    let datasetSize = 7 * 512 * 1024 # 7 blocks of data
    let dataset = await testbed.dataset.data(datasetSize).upload(node)
    let status = await testbed.api(node).status(!dataset.cid)
    check status["cid"].getStr() == !dataset.cid
    check status["status"].getStr() == "Completed"
    check status["blocks"].getStr() == "0b1111111"
