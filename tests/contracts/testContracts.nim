import pkg/chronos
import pkg/ethers/erc20
import archivist/contracts
import ../asynctest
import ../testbed
import ./examples
import ./deployment

suite "Marketplace contracts":
  var testbed: Testbed
  var hardhat: Hardhat
  var provider: JsonRpcProvider
  var accounts: seq[Address]

  setupAll:
    testbed = await Testbed.start()
    hardhat = await testbed.hardhat.start()
    provider = testbed.eth.provider
    accounts = await provider.listAccounts()

  teardownAll:
    await testbed.stop()

  let proof = Groth16Proof.example

  var client, host: Signer
  var rewardRecipient, collateralRecipient: Address
  var marketplace: MarketplaceContract
  var token: Erc20Token
  var periodicity: Periodicity
  var request: StorageRequest
  var slotId: SlotId
  var filledAt: uint64

  proc expectedPayout(endTimestamp: uint64): UInt256 =
    return (endTimestamp - filledAt).u256 * request.ask.pricePerSlotPerSecond()

  proc switchAccount(account: Signer) =
    marketplace = marketplace.connect(account)
    token = token.connect(account)

  setup:
    client = provider.getSigner(accounts[0])
    host = provider.getSigner(accounts[1])
    rewardRecipient = accounts[2]
    collateralRecipient = accounts[3]

    let address = MarketplaceContract.address(dummyVerifier = true)
    marketplace = MarketplaceContract.new(address, provider.getSigner())

    let tokenAddress = await marketplace.token()
    token = Erc20Token.new(tokenAddress, provider.getSigner())

    let config = await marketplace.configuration()
    periodicity = Periodicity(seconds: config.proofs.period)

    request = StorageRequest.example
    request.client = await client.getAddress()

    switchAccount(client)
    discard await token.approve(marketplace.address, request.totalPrice).confirm(1)
    discard await marketplace.requestStorage(request).confirm(1)
    switchAccount(host)
    discard
      await token.approve(marketplace.address, request.ask.collateralPerSlot).confirm(1)
    discard await marketplace.reserveSlot(request.id, 0.uint64).confirm(1)
    let receipt = await marketplace.fillSlot(request.id, 0.uint64, proof).confirm(1)
    filledAt = await testbed.eth.time.blockTime(BlockTag.init(!receipt.blockNumber))
    slotId = request.slotId(0.uint64)

  teardown:
    await hardhat.reset()

  proc waitUntilProofRequired(slotId: SlotId) {.async.} =
    let currentPeriod = periodicity.periodOf((await testbed.eth.time.now()).uint64)
    await testbed.eth.time.advanceTo(periodicity.periodEnd(currentPeriod))
    while not (
      (await marketplace.isProofRequired(slotId)) and
      (await marketplace.getPointer(slotId)) < 250
    )
    :
      await testbed.eth.time.advance(periodicity.seconds)

  proc startContract() {.async.} =
    for slotIndex in 1 ..< request.ask.slots:
      discard await token
      .approve(marketplace.address, request.ask.collateralPerSlot)
      .confirm(1)
      discard await marketplace.reserveSlot(request.id, slotIndex.uint64).confirm(1)
      discard await marketplace.fillSlot(request.id, slotIndex.uint64, proof).confirm(1)

  test "accept marketplace proofs":
    switchAccount(host)
    await waitUntilProofRequired(slotId)
    discard await marketplace.submitProof(slotId, proof).confirm(1)

  test "can mark missing proofs":
    switchAccount(host)
    await waitUntilProofRequired(slotId)
    let missingPeriod = periodicity.periodOf((await testbed.eth.time.now()).uint64)
    let endOfPeriod = periodicity.periodEnd(missingPeriod)
    await testbed.eth.time.advanceTo(endOfPeriod + 1)
    switchAccount(client)
    discard await marketplace.markProofAsMissing(slotId, missingPeriod).confirm(1)

  test "can be paid out at the end":
    switchAccount(host)
    let address = await host.getAddress()
    await startContract()
    let requestEnd = (await marketplace.requestEnd(request.id)).uint64
    await testbed.eth.time.advanceTo(requestEnd + 1)
    let startBalance = await token.balanceOf(address)
    discard await marketplace.freeSlot(slotId).confirm(1)
    let endBalance = await token.balanceOf(address)
    check endBalance ==
      (startBalance + expectedPayout(requestEnd) + request.ask.collateralPerSlot)

  test "can be paid out at the end, specifying reward and collateral recipient":
    switchAccount(host)
    let hostAddress = await host.getAddress()
    await startContract()
    let requestEnd = (await marketplace.requestEnd(request.id)).uint64
    await testbed.eth.time.advanceTo(requestEnd + 1)
    let startBalanceHost = await token.balanceOf(hostAddress)
    let startBalanceReward = await token.balanceOf(rewardRecipient)
    let startBalanceCollateral = await token.balanceOf(collateralRecipient)
    discard await marketplace
    .freeSlot(slotId, rewardRecipient, collateralRecipient)
    .confirm(1)
    let endBalanceHost = await token.balanceOf(hostAddress)
    let endBalanceReward = await token.balanceOf(rewardRecipient)
    let endBalanceCollateral = await token.balanceOf(collateralRecipient)

    check endBalanceHost == startBalanceHost
    check endBalanceReward == (startBalanceReward + expectedPayout(requestEnd))
    check endBalanceCollateral ==
      (startBalanceCollateral + request.ask.collateralPerSlot)

  test "cannot mark proofs missing for cancelled request":
    let expiry = (await marketplace.requestExpiry(request.id)).uint64
    await testbed.eth.time.advanceTo(expiry + 1)
    switchAccount(client)
    let missingPeriod = periodicity.periodOf((await testbed.eth.time.now()).uint64)
    await testbed.eth.time.advance(periodicity.seconds)
    expect Marketplace_SlotNotAcceptingProofs:
      discard await marketplace.markProofAsMissing(slotId, missingPeriod).confirm(1)
