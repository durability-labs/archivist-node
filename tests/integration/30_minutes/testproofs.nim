import pkg/asynctest/chronos/unittest2
import ../../testbed

suite "Storage Proofs":
  var testbed: Testbed

  setup:
    testbed = await Testbed.start()
    discard await testbed.hardhat.start()

  teardown:
    await testbed.stop()

  test "hosts submit periodic proofs for slots they fill":
    discard await testbed.node.provider.start()
    let node = await testbed.node.persistence.start()
    discard await testbed.request.start(node)
    let submitted = await testbed.marketplace.recordProofSubmitted()
    await submitted.waitForProofSubmitted()

  test "slot is freed after too many invalid proofs are submitted":
    discard await testbed.node.provider.failProofs(every = 1).start()
    discard await testbed.node.validator.start()
    let node = await testbed.node.persistence.start()
    let freed = await testbed.marketplace.recordSlotFreed()
    let request = await testbed.request.start(node)
    await freed.waitForSlotFreed(request.id)
