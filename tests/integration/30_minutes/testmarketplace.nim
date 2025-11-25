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

  test "provider can fill slots that were posted before it made storage available":
    let provider = await testbed.node.provider.availability(false).start()
    let node = await testbed.node.persistence.start()
    let request = await testbed.request.submit(node)
    let started = await testbed.marketplace.recordRequestStarted()
    await testbed.availability.update(provider)
    await started.waitForRequestStarted(request.id)

  test "provider withdraws its payout when a request ends":
    let provider = await testbed.node.provider.start()
    let node = await testbed.node.persistence.start()
    let request = await testbed.request.start(node)
    let transfers = await testbed.marketplace.recordTransfers()
    await testbed.eth.time.advance(request.duration)
    await transfers.waitForTransferTo(provider)

  test "requester withdraws remaining funds when a request ends":
    discard await testbed.node.provider.start()
    let node = await testbed.node.persistence.start()
    let request = await testbed.request.start(node)
    let transfers = await testbed.marketplace.recordTransfers()
    await testbed.eth.time.advance(request.duration)
    await transfers.waitForTransferTo(node)

  test "provider withdraws its payout when a request is cancelled":
    let provider = await testbed.node.provider.start()
    let node = await testbed.node.persistence.start()
    let filled = await testbed.marketplace.recordSlotFilled()
    let request = await testbed.request.submit(node)
    await filled.waitForSlotFilled(request.id)
    let transfers = await testbed.marketplace.recordTransfers()
    await testbed.eth.time.advance(request.expiry)
    await transfers.waitForTransferTo(provider)

  test "requester withdraws remaining funds when a request is cancelled":
    let node = await testbed.node.persistence.start()
    let request = await testbed.request.submit(node)
    let transfers = await testbed.marketplace.recordTransfers()
    await testbed.eth.time.advance(request.expiry)
    await transfers.waitForTransferTo(node)
