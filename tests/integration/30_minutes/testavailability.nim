import std/json
import std/strutils
import pkg/asynctest/chronos/unittest2
import ../../testbed

suite "Availability":
  var testbed: Testbed
  var node, provider: Node

  setup:
    testbed = await Testbed.start()
    discard await testbed.hardhat.start()
    node = await testbed.node.persistence.start()
    provider = await testbed.node.provider.availability(false).start()

  teardown:
    await testbed.stop()

  test "node handles new sales availability terms":
    await testbed.availability.update(provider)

  test "node handles availability updates":
    await testbed.availability.update(provider)
    let until = (await testbed.eth.time.now()) + 100
    await testbed.availability
    .maximumDuration(100)
    .minimumPricePerBytePerSecond(2)
    .maximumCollateralPerByte(200)
    .availableUntil(until)
    .update(provider)
    let updated = await testbed.api(provider).getAvailability()
    check updated{"maximumDuration"} == %"100"
    check updated{"minimumPricePerBytePerSecond"} == %"2"
    check updated{"maximumCollateralPerByte"} == %"200"
    check updated{"availableUntil"} == %($until)

suite "Availability validation":
  var testbed: Testbed
  var provider: Node

  setupAll:
    testbed = await Testbed.start()
    discard await testbed.hardhat.start()
    provider = await testbed.node.provider.availability(false).start()

  teardownAll:
    await testbed.stop()

  test "node refuses to create availability of zero duration":
    try:
      await testbed.availability.maximumDuration(0).update(provider)
      fail()
    except HttpError as error:
      check "422" in error.msg
      check "maximumDuration must be larger than zero" in error.msg

  test "node refuses to create availability with zero price":
    try:
      await testbed.availability.minimumPricePerBytePerSecond(0).update(provider)
      fail()
    except HttpError as error:
      check "422" in error.msg
      check "minimumPricePerBytePerSecond must be larger than zero" in error.msg

  test "node refuses to create availability with zero collateral":
    try:
      await testbed.availability.maximumCollateralPerByte(0).update(provider)
      fail()
    except HttpError as error:
      check "422" in error.msg
      check "maximumCollateralPerByte must be larger than zero" in error.msg

  test "node rejects a negative value for 'availableUntil'":
    let availability =
      %*{
        "maximumDuration": 1,
        "minimumPricePerBytePerSecond": 1,
        "maximumCollateralPerByte": 1,
        "availableUntil": -1,
      }
    try:
      await testbed.api(provider).updateAvailability(availability)
      fail()
    except HttpError as error:
      check "400" in error.msg
      check "[-] is not a decimal character" in error.msg
