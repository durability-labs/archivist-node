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

  test "node handles new storage availability":
    let availability1 = await testbed.availability.create(provider)
    let availability2 = await testbed.availability.create(provider)
    check availability1{"id"} != availability2{"id"}

  test "node lists storage that is for sale":
    let availability = await testbed.availability.create(provider)
    check availability in await testbed.api(provider).getAvailability()

  test "node reserves quota for availability":
    let before = await testbed.api(provider).getSpace()
    let availability = await testbed.availability.create(provider)
    let after = await testbed.api(provider).getSpace()
    let reservedBefore = before["quotaReservedBytes"].getInt()
    let reservedAfter = after["quotaReservedBytes"].getInt()
    let availabilitySize = availability["totalSize"].getInt()
    check reservedBefore == 0
    check reservedAfter == availabilitySize

  test "node handles availability updates":
    let original = await testbed.availability.create(provider)
    let id = original["id"].getStr()
    let until = (await testbed.eth.time.now()) + 100
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

  test "node refuses to decrease totalSize below amount used by slots":
    let original = await testbed.availability.create(provider)
    let id = original["id"].getStr()
    let request = await testbed.request.submit(node)
    await testbed.marketplace.waitForSlotFilled(request.id)
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
    let request = await testbed.request.submit(node)
    await testbed.marketplace.waitForSlotFilled(request.id)
    await sleepAsync(chronos.seconds(1))
    try:
      let until = (await testbed.eth.time.now()) + 1
      await testbed.availability.until(until).update(provider, id)
      fail()
    except HttpError as error:
      check "422" in error.msg
      check "greater or equal to the longest currently hosted slot" in error.msg

suite "Availability validation":

  var testbed: Testbed
  var provider: Node

  setupAll: # use a single testbed for all tests
    testbed = await Testbed.start()
    discard await testbed.hardhat.start()
    provider = await testbed.node.provider.availability(false).start()

  teardownAll:
    await testbed.stop()

  test "node refuses to change freeSize":
    try:
      let availability = await testbed.availability.create(provider)
      let id = availability["id"].getStr()
      await testbed.api(provider).updateAvailability(id, %*{"freeSize": 100})
      fail()
    except HttpError as error:
      check "422" in error.msg
      check "not allowed" in error.msg

  test "node rejects update to non-existing availability":
    try:
      let invalidId =
        "11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff"
      await testbed.availability.totalSize(100).update(provider, invalidId)
      fail()
    except HttpError as error:
      check "404" in error.msg

  test "node refuses to create availability of zero size":
    try:
      discard await testbed.availability.totalSize(0).create(provider)
      fail()
    except HttpError as error:
      check "422" in error.msg
      check "Total size must be larger then zero" in error.msg

  test "node refuses to update totalSize to zero":
    let availability = await testbed.availability.create(provider)
    let id = availability["id"].getStr()
    try:
      await testbed.availability.totalSize(0).update(provider, id)
      fail()
    except HttpError as error:
      check "422" in error.msg
      check "Total size must be > 0 and <= 9223372036854775807" in error.msg

  test "node refuses to create availability of negative size":
    try:
      discard await testbed.availability.totalSize(-1).create(provider)
      fail()
    except HttpError as error:
      check "400" in error.msg
      check "[-] is not a decimal character" in error.msg

  test "node refuses to update totalSize to a negative value":
    let availability = await testbed.availability.create(provider)
    let id = availability["id"].getStr()
    try:
      await testbed.availability.totalSize(-1).update(provider, id)
      fail()
    except HttpError as error:
      check "422" in error.msg
      check "Total size must be > 0 and <= 9223372036854775807" in error.msg

  test "node refuses to create availability larger than the node quota":
    let space = await testbed.api(provider).getSpace()
    let quota = space["quotaMaxBytes"].getInt()
    try:
      discard await testbed.availability.totalSize(quota + 1).create(provider)
      fail()
    except HttpError as error:
      check "422" in error.msg
      check "Not enough storage quota" in error.msg

  test "node refuses to update totalSize above the node quota":
    let availability = await testbed.availability.create(provider)
    let id = availability["id"].getStr()
    let space = await testbed.api(provider).getSpace()
    let quota = space["quotaMaxBytes"].getInt()
    try:
      await testbed.availability.totalSize(quota + 1).update(provider, id)
      fail()
    except HttpError as error:
      check "422" in error.msg
      check "Not enough storage quota" in error.msg

  test "node refuses to create availability of zero duration":
    try:
      discard await testbed.availability.duration(0).create(provider)
      fail()
    except HttpError as error:
      check "422" in error.msg
      check "duration must be larger then zero" in error.msg

  test "node refuses to create availability with zero price":
    try:
      discard await testbed
        .availability
        .minPricePerBytePerSecond(0)
        .create(provider)
      fail()
    except HttpError as error:
      check "422" in error.msg
      check "minPricePerBytePerSecond must be larger then zero" in error.msg

  test "node refuses to create availability with zero collateral":
    try:
      discard await testbed
        .availability
        .totalCollateral(0)
        .create(provider)
      fail()
    except HttpError as error:
      check "422" in error.msg
      check "totalCollateral must be larger then zero" in error.msg

  test "node rejects a negative value for 'until'":
    let original = await testbed.availability.create(provider)
    let id = original["id"].getStr()
    try:
      await testbed.api(provider).updateAvailability(id, %*{"until": -1})
      fail()
    except HttpError as error:
      check "422" in error.msg
      check "Cannot set until to a negative value" in error.msg
