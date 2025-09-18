import std/json
import std/strutils
import pkg/asynctest/chronos/unittest2
import ../../testbed

suite "Purchasing":
  var testbed: Testbed
  var node: Node

  setup:
    testbed = await Testbed.start()
    discard await testbed.hardhat.start()
    node = await testbed.node.persistence.start()

  teardown:
    await testbed.stop()

  test "node handles storage request":
    let request1 = await testbed.request.submit(node)
    let request2 = await testbed.request.submit(node)
    check request1.id != request2.id

  test "node returns purchase status":
    let request = await testbed.request
    .duration(100)
    .pricePerBytePerSecond(4)
    .proofProbability(6)
    .expiry(30)
    .collateralPerByte(2)
    .nodes(3)
    .tolerance(1)
    .submit(node)
    let purchase = await testbed.api(node).getPurchase(request.id)
    check purchase["request"]["content"]["cid"].getStr().len > 0
    check purchase["request"]["expiry"] == %30
    check purchase["request"]["ask"]["duration"] == %100
    check purchase["request"]["ask"]["pricePerBytePerSecond"] == %"4"
    check purchase["request"]["ask"]["proofProbability"] == %"6"
    check purchase["request"]["ask"]["collateralPerByte"] == %"2"
    check purchase["request"]["ask"]["slots"] == %3
    check purchase["request"]["ask"]["maxSlotLoss"] == %1

  test "node remembers purchase status after restart":
    let request = await testbed.request.submit(node)
    await node.restart()
    check:
      eventually:
        let purchase = await testbed.api(node).getPurchase(request.id)
        purchase["state"] == %"submitted" and
          purchase["request"]["expiry"] == %request.expiry and
          purchase["request"]["ask"]["duration"] == %request.duration

suite "Purchasing storage request validation":
  var testbed: Testbed
  var node: Node

  setupAll:
    testbed = await Testbed.start()
    discard await testbed.hardhat.start()
    node = await testbed.node.persistence.start()

  teardownAll:
    await testbed.stop()

  test "expiry should not be zero":
    try:
      discard await testbed.request.expiry(0).submit(node)
      fail()
    except HttpError as error:
      check "422" in error.msg
      check "must be greater than zero" in error.msg

  test "expiry should less than the duration":
    try:
      discard await testbed.request.expiry(100).duration(100).submit(node)
      fail()
    except HttpError as error:
      check "422" in error.msg
      check "less than the request's duration" in error.msg

  test "tolerance should not be zero":
    try:
      discard await testbed.request.tolerance(0).submit(node)
      fail()
    except HttpError as error:
      check "422" in error.msg
      check "Tolerance needs to be bigger then zero" in error.msg

  test "rejects for data that is too small for erasure coding":
    let dataset = await testbed.dataset.data("tiny").upload(node)
    try:
      discard await testbed.request.dataset(dataset).submit(node)
      fail()
    except HttpError as error:
      check "422" in error.msg
      check "Dataset too small for erasure parameters" in error.msg

  test "rejects invalid erasure coding parameters":
    for (nodes, tolerance) in [(1, 1), (2, 1), (3, 2), (3, 3)]:
      try:
        discard await testbed.request.nodes(nodes).tolerance(tolerance).submit(node)
        fail()
      except HttpError as error:
        check "422" in error.msg
        check "must satify `1 < (nodes - tolerance) ≥ tolerance`" in error.msg

  test "duration should not exceed limit":
    const limit = 30 * 24 * 60 * 60
    try:
      discard await testbed.request.duration(limit + 1).submit(node)
      fail()
    except HttpError as error:
      check "422" in error.msg
      check "Duration exceeds limit" in error.msg

  test "proof probability should not be zero":
    try:
      discard await testbed.request.proofProbability(0).submit(node)
      fail()
    except HttpError as error:
      check "422" in error.msg
      check "Proof probability must be greater than zero" in error.msg

  test "price should not be zero":
    try:
      discard await testbed.request.pricePerBytePerSecond(0).submit(node)
      fail()
    except HttpError as error:
      check "422" in error.msg
      check "Price per byte per second must be greater than zero" in error.msg

  test "collateral should not be zero":
    try:
      discard await testbed.request.collateralPerByte(0).submit(node)
      fail()
    except HttpError as error:
      check "422" in error.msg
      check "Collateral per byte must be greater than zero" in error.msg
