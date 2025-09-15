import std/json
import std/strutils
import pkg/asynctest/chronos/unittest2
import ../../testbed

suite "Sales availability":

  var testbed: Testbed
  var node, provider: Node

  setup:
    testbed = await Testbed.start()
    discard await testbed.hardhat.start()
    node = await testbed.node.persistence.start()
    provider = await testbed.node.provider.availability(false).start()

  teardown:
    await testbed.stop()

  test "node handles new storage availability":
    let availability1 = await testbed.availability.create(provider)
    let availability2 = await testbed.availability.create(provider)
    check availability1{"id"} != availability2{"id"}

  test "node lists storage that is for sale":
    let availability = await testbed.availability.create(provider)
    check availability in await testbed.api(provider).getAvailability()

  test "node handles availability updates":
    let original = await testbed.availability.create(provider)
    let id = original["id"].getStr()
    let until = (await testbed.time.now()) + 100
    await testbed
      .availability
      .duration(100)
      .minPricePerBytePerSecond(2)
      .totalCollateral(200)
      .enabled(false)
      .until(until)
      .update(provider, id)
    let updated = (await testbed.api(provider).getAvailability())[0]
    check updated{"duration"} == %100
    check updated{"minPricePerBytePerSecond"} == %"2"
    check updated{"totalCollateral"} == %"200"
    check updated{"totalSize"} == original{"totalSize"}
    check updated{"freeSize"} == original{"freeSize"}
    check updated{"enabled"} == %false
    check updated{"until"} == %until

  test "node handles updates to totalSize":
    let original = await testbed.availability.create(provider)
    let id = original["id"].getStr()
    await testbed.availability.totalSize(100).update(provider, id)
    let updated = (await testbed.api(provider).getAvailability())[0]
    check updated{"totalSize"} == %100
    check updated{"freeSize"} == %100

  test "node refuses a negative value for 'until'":
    let original = await testbed.availability.create(provider)
    let id = original["id"].getStr()
    try:
      await testbed.availability.until(-1).update(provider, id)
      fail()
    except HttpError as error:
      check "422" in error.msg
      check "Cannot set until to a negative value" in error.msg

  test "node refuses to decrease totalSize below amount used by slots":
    let original = await testbed.availability.create(provider)
    let id = original["id"].getStr()
    discard await testbed.request.start(node)
    let updated = (await testbed.api(provider).getAvailability())[0]
    check updated["totalSize"].getInt() == original["totalSize"].getInt()
    check updated["freeSize"].getInt() < original["freeSize"].getInt()
    try:
      let used = updated["totalSize"].getInt() - updated["freeSize"].getInt()
      await testbed.availability.totalSize(used - 1).update(provider, id)
      fail()
    except HttpError as error:
      check "422" in error.msg
      check "must be larger then current totalSize - freeSize" in error.msg

  test "node refuses to decrease 'until' below request end":
    let original = await testbed.availability.create(provider)
    let id = original["id"].getStr()
    discard await testbed.request.start(node)
    await sleepAsync(chronos.seconds(1))
    try:
      let until = (await testbed.time.now()) + 1
      await testbed.availability.until(until).update(provider, id)
      fail()
    except HttpError as error:
      check "422" in error.msg
      check "greater or equal to the longest currently hosted slot" in error.msg

  test "node returns amount of reserved quota":
    let before = await testbed.api(provider).getSpace()
    let availability = await testbed.availability.create(provider)
    let after = await testbed.api(provider).getSpace()
    let reservedBefore = before["quotaReservedBytes"].getInt()
    let reservedAfter = after["quotaReservedBytes"].getInt()
    let availabilitySize = availability["totalSize"].getInt()
    check reservedBefore == 0
    check reservedAfter == availabilitySize
