import pkg/asynctest/chronos/unittest2
import ../../testbed

suite "Repair":
  var testbed: Testbed

  setup:
    testbed = await Testbed.start()
    discard await testbed.hardhat.start()

  teardown:
    await testbed.stop()

  test "slot can be restored from slots on other providers":
    # setup node, validator and 3 providers
    let node = await testbed.node.persistence.start()
    discard await testbed.node.validator.start()
    let provider1 = await testbed.node.provider.availability(false).start()
    let provider2 = await testbed.node.provider.availability(false).start()
    let provider3 = await testbed.node.provider.availability(false).start()

    # submit request
    let request = await testbed.request.nodes(3).submit(node)
    let size = request.dataset.data.len

    # ensure that each provider can only fill a single slot
    discard await testbed.availability.totalSize(size div 2).create(provider1)
    discard await testbed.availability.totalSize(size div 2).create(provider2)
    discard await testbed.availability.totalSize(size div 2).create(provider3)

    # wait for request to start
    await testbed.marketplace.waitForRequestStarted(request.id)

    # stop node and one provider
    await node.stop()
    await provider1.stop()

    # ensure that remaining providers can fill the missing slot
    discard await testbed.availability.totalSize(size div 2).create(provider2)
    discard await testbed.availability.totalSize(size div 2).create(provider3)

    # wait for slot to be filled
    await testbed.marketplace.waitForSlotFilled(request.id)
