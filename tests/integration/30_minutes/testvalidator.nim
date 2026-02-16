import pkg/asynctest/chronos/unittest2
import ../../testbed

suite "Validator":
  var testbed: Testbed

  setup:
    testbed = await Testbed.start()
    discard await testbed.hardhat.start()

  teardown:
    await testbed.stop()

  test "validator marks proofs as missing":
    let node = await testbed.node.log("archivist", "validator").persistence.start()
    discard await testbed.node.provider.failProofs(every = 1).start()
    discard await testbed.node.validator.start()
    let failed = await testbed.marketplace.recordRequestFailed()
    let request = await testbed.request.start(node)
    echo "DEBUG: Request started, waiting for failure..."
    await failed.waitForRequestFailed(request.id)
    echo "DEBUG: Request marked as failed!"

  test "validator marks proofs as missing when using validation groups":
    let node = await testbed.node.log("archivist", "validator").persistence.start()
    discard await testbed.node.provider.failProofs(every = 1).start()
    discard await testbed.node.validator(groups = 2, index = 0).start()
    discard await testbed.node.validator(groups = 2, index = 1).start()
    let failed = await testbed.marketplace.recordRequestFailed()
    let request = await testbed.request.start(node)
    await failed.waitForRequestFailed(request.id)

  test "validator uses historical state to mark proofs as missing":
    let node = await testbed.node.log("archivist", "validator").persistence.start()
    discard await testbed.node.provider.failProofs(every = 1).start()
    let request = await testbed.request.start(node)
    let failed = await testbed.marketplace.recordRequestFailed()
    discard await testbed.node.validator(groups = 2, index = 0).start()
    discard await testbed.node.validator(groups = 2, index = 1).start()
    await testbed.eth.time.advance(1) # ensures that validators sync their clock
    await failed.waitForRequestFailed(request.id)
