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
    debugEcho "1"
    discard await testbed.node.provider.log("contracts", "clock").start()
    debugEcho "2"
    let node = await testbed.node.persistence.start()
    debugEcho "3"
    discard await testbed.request.start(node)
    debugEcho "4"
    await testbed.marketplace.waitForProofSubmitted()
    debugEcho "5"

  test "slot is freed after too many invalid proofs are submitted":
    debugEcho "1"
    discard await testbed.node.provider.failProofs(every = 1).start()
    debugEcho "2"
    discard await testbed.node.validator.start()
    debugEcho "3"
    let node = await testbed.node.persistence.start()
    debugEcho "4"
    let request = await testbed.request.start(node)
    debugEcho "5"
    await testbed.marketplace.waitForSlotFreed(request.id)
    debugEcho "6"
