import pkg/chronos
import pkg/ethers
import pkg/ethers/erc20
import pkg/questionable
import pkg/stew/byteutils
import ../network/hardhat
import ../network/node
import ../network/contract
import ../testbed
import ../error
import ./api

type MarketplaceBuilder = ref object
  testbed: Testbed
  contractInstance: ?MarketplaceContract
  tokenInstance: ?Erc20Token
  vaultInstance: ?Address

func marketplace*(testbed: Testbed): MarketplaceBuilder =
  MarketplaceBuilder(testbed: testbed)

proc contract(builder: MarketplaceBuilder): MarketplaceContract =
  without var contract =? builder.contractInstance:
    let hardhat = builder.testbed.hardhatInstance
    let provider = builder.testbed.provider
    without address =? Address.init(hardhat.marketplaceAddress):
      raise newException(TestbedError, "invalid marketplace address")
    contract = MarketplaceContract.new(address, provider)
    builder.contractInstance = some contract
  contract

proc token(builder: MarketplaceBuilder): Future[Erc20Token] {.async.} =
  without var token =? builder.tokenInstance:
    let address = await builder.contract.token
    let provider = builder.testbed.provider
    token = Erc20Token.new(address, provider)
    builder.tokenInstance = some token
  token

proc vault(builder: MarketplaceBuilder): Future[Address] {.async.} =
  without var vault =? builder.vaultInstance:
    vault = await builder.contract.vault
    builder.vaultInstance = some vault
  vault

type Recording[Event] = ref object
  builder: MarketplaceBuilder
  subscription: Subscription
  events: AsyncQueue[Event]

proc record(
    builder: MarketplaceBuilder, contract: Contract, Event: type
): Future[Recording[Event]] {.async.} =
  let recording = Recording[Event](builder: builder, events: newAsyncQueue[Event]())
  proc onEvent(event: Event) =
    try:
      recording.events.putNoWait(event)
    except AsyncQueueFullError as error:
      raiseAssert error.msg

  recording.subscription = await contract.subscribe(Event, onEvent)
  recording

template waitForIt(
    recording: Recording, timeout: Duration, condition: untyped
): Future[void] =
  block:
    proc waiting() {.gensym, async.} =
      while true:
        let it {.inject, used.} = await recording.events.get()
        if condition:
          break
      await recording.subscription.unsubscribe()

    proc waitingTimeout() {.gensym, async.} =
      if not await waiting().withTimeout(timeout):
        raiseAssert "marketplace timeout exceeded (" & $timeout & ")"

    waitingTimeout()

proc recordStorageRequested*(
    builder: MarketplaceBuilder
): Future[Recording[StorageRequested]] {.async.} =
  await builder.record(builder.contract, StorageRequested)

proc waitForStorageRequested*(
    recording: Recording[StorageRequested], requestId: string, timeout = 10.minutes
) {.async.} =
  let requestId = hexToByteArray(requestId, 32)
  await recording.waitForIt(timeout, it.requestId == requestid)

proc recordSlotFilled*(
    builder: MarketplaceBuilder
): Future[Recording[SlotFilled]] {.async.} =
  await builder.record(builder.contract, SlotFilled)

proc waitForSlotFilled*(
    recording: Recording[SlotFilled], requestId: string, timeout = 10.minutes
) {.async.} =
  let requestId = hexToByteArray(requestId, 32)
  await recording.waitForIt(timeout, it.requestId == requestid)

proc recordRequestStarted*(
    builder: MarketplaceBuilder
): Future[Recording[RequestFulfilled]] {.async.} =
  await builder.record(builder.contract, RequestFulfilled)

proc waitForRequestStarted*(
    recording: Recording[RequestFulfilled], requestId: string, timeout = 10.minutes
) {.async.} =
  let requestId = hexToByteArray(requestId, 32)
  await recording.waitForIt(timeout, it.requestId == requestid)

proc recordRequestFailed*(
    builder: MarketplaceBuilder
): Future[Recording[RequestFailed]] {.async.} =
  await builder.record(builder.contract, RequestFailed)

proc waitForRequestFailed*(
    recording: Recording[RequestFailed], requestId: string, timeout = 10.minutes
) {.async.} =
  let requestId = hexToByteArray(requestId, 32)
  await recording.waitForIt(timeout, it.requestId == requestId)

proc recordProofSubmitted*(
    builder: MarketplaceBuilder
): Future[Recording[ProofSubmitted]] {.async.} =
  await builder.record(builder.contract, ProofSubmitted)

proc waitForProofSubmitted*(
    recording: Recording[ProofSubmitted], timeout = 10.minutes
) {.async.} =
  await recording.waitForIt(timeout, true)

proc recordSlotFreed*(
    builder: MarketplaceBuilder
): Future[Recording[SlotFreed]] {.async.} =
  await builder.record(builder.contract, SlotFreed)

proc waitForSlotFreed*(
    recording: Recording[SlotFreed], requestId: string, timeout = 10.minutes
) {.async.} =
  let requestId = hexToByteArray(requestId, 32)
  await recording.waitForIt(timeout, it.requestId == requestId)

proc recordTransfers*(
    builder: MarketplaceBuilder
): Future[Recording[Transfer]] {.async.} =
  await builder.record(await builder.token, Transfer)

proc waitForTransferTo*(
    recording: Recording[Transfer], node: Node, timeout = 10.minutes
) {.async.} =
  let builder = recording.builder
  let sender = await builder.vault
  without receiver =? await builder.testbed.api(node).getEthAddress():
    raise newException(TestbedError, "node does not have an eth address")
  await recording.waitForIt(timeout, it.sender == sender and it.receiver == receiver)
