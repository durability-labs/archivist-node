import ../../asynctest
import ../testbed

suite "Storage Proofs":

  var testbed: Testbed

  setup:
    testbed = await Testbed.start()
    await testbed.hardhat.start()

  teardown:
    await testbed.stop()

  test "slot is freed after too many invalid proofs are submitted":
    await testbed.node.provider.failProofs(every = 1).start()
    await testbed.request.start()
