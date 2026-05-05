import std/json
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
    let provider1 = await testbed.node.provider.start()
    let provider2 = await testbed.node.provider.start()
    let provider3 = await testbed.node.provider.start()

    # start request
    # 9 slots makes the odds that all slots are filled by one node negligable
    # tolerance of 4 ensures that there's always a node that we can stop
    let request = await testbed.request.nodes(9).tolerance(4).start(node)

    # stop node
    await node.stop()

    # record new slot filled events
    let filled = await testbed.marketplace.recordSlotFilled()

    # stop a provider with at least one slot, and within tolerance
    for provider in [provider1, provider2, provider3]:
      let slots = await testbed.api(provider).getSlots()
      if 1 <= slots.len and slots.len <= 4:
        await provider.stop()
        break

    # wait for slot to be repaired
    await filled.waitForSlotFilled(request.id, timeout = 30.minutes)
