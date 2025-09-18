import std/json
import pkg/asynctest/chronos/unittest2
import ../../testbed

suite "Marketplace":
  var testbed: Testbed

  setup:
    testbed = await Testbed.start()
    discard await testbed.hardhat.start()

  teardown:
    await testbed.stop()

  test "nodes negotiate contracts on the marketplace":
    discard await testbed.node.provider.start()
    let node = await testbed.node.persistence.start()
    let request = await testbed.request.start(node)
    let purchase = await testbed.api(node).getPurchase(request.id)
    check purchase["error"].kind == JNull

  test "provider uses part of its availability when filling slots":
    let provider = await testbed.node.provider.start()
    let node = await testbed.node.persistence.start()
    let before = await testbed.api(provider).getAvailability()
    discard await testbed.request.start(node)
    let after = await testbed.api(provider).getAvailability()
    check after[0]["freeSize"].getInt < before[0]["freeSize"].getInt

  test "provider can fill slots that were posted before it had availability":
    let provider = await testbed.node.provider.availability(false).start()
    let node = await testbed.node.persistence.start()
    let request = await testbed.request.submit(node)
    discard await testbed.availability.create(provider)
    await testbed.marketplace.waitForRequestStarted(request.id)

  test "provider withdraws its payout when a request ends":
    let provider = await testbed.node.provider.start()
    let node = await testbed.node.persistence.start()
    let request = await testbed.request.start(node)
    await testbed.eth.time.advance(request.duration)
    await testbed.marketplace.waitForTransferTo(provider)

  test "requester withdraws remaining funds when a request ends":
    discard await testbed.node.provider.start()
    let node = await testbed.node.persistence.start()
    let request = await testbed.request.start(node)
    await testbed.eth.time.advance(request.duration)
    await testbed.marketplace.waitForTransferTo(node)

  test "provider withdraws its payout when a request is cancelled":
    let provider = await testbed.node.provider.start()
    let node = await testbed.node.persistence.start()
    let request = await testbed.request.submit(node)
    await testbed.marketplace.waitForSlotFilled(request.id)
    await testbed.eth.time.advance(request.expiry)
    await testbed.marketplace.waitForTransferTo(provider)

  test "requester withdraws remaining funds when a request is cancelled":
    let node = await testbed.node.persistence.start()
    let request = await testbed.request.submit(node)
    await testbed.eth.time.advance(request.expiry)
    await testbed.marketplace.waitForTransferTo(node)
