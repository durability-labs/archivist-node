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
  token

proc waitForStorageRequested*(
  builder: MarketplaceBuilder,
  requestId: string
) {.async.} =
  let requestId = hexToByteArray(requestId, 32)
  let done = newAsyncEvent()
  proc onEvent(event: ?!StorageRequested) =
    if (!event).requestId == requestId:
      done.fire()
  let contract = builder.contract
  let subscription = await contract.subscribe(StorageRequested, onEvent)
  await done.wait()
  await subscription.unsubscribe()

proc waitForSlotFilled*(
  builder: MarketplaceBuilder,
  requestId: string
) {.async.} =
  let requestId = hexToByteArray(requestId, 32)
  let done = newAsyncEvent()
  proc onEvent(event: ?!SlotFilled) =
    if (!event).requestId == requestId:
      done.fire()
  let contract = builder.contract
  let subscription = await contract.subscribe(SlotFilled, onEvent)
  await done.wait()
  await subscription.unsubscribe()

proc waitForRequestStarted*(
  builder: MarketplaceBuilder,
  requestId: string
) {.async.} =
  let requestId = hexToByteArray(requestId, 32)
  let done = newAsyncEvent()
  proc onEvent(event: ?!RequestFulfilled) =
    if (!event).requestId == requestId:
      done.fire()
  let contract = builder.contract
  let subscription = await contract.subscribe(RequestFulfilled, onEvent)
  await done.wait()
  await subscription.unsubscribe()

proc waitForRequestFailed*(
  builder: MarketplaceBuilder,
  requestId: string
) {.async.} =
  let requestId = hexToByteArray(requestId, 32)
  let done = newAsyncEvent()
  proc onEvent(event: ?!RequestFailed) =
    if (!event).requestId == requestId:
      done.fire()
  let contract = builder.contract
  let subscription = await contract.subscribe(RequestFailed, onEvent)
  await done.wait()
  await subscription.unsubscribe()

proc waitForProofSubmitted*(builder: MarketplaceBuilder) {.async.} =
  let done = newAsyncEvent()
  proc onEvent(event: ?!ProofSubmitted) =
    discard !event
    done.fire()
  let contract = builder.contract
  let subscription = await contract.subscribe(ProofSubmitted, onEvent)
  await done.wait()
  await subscription.unsubscribe()

proc waitForSlotFreed*(
  builder: MarketplaceBuilder,
  requestId: string
) {.async.} =
  let requestId = hexToByteArray(requestId, 32)
  let done = newAsyncEvent()
  proc onEvent(event: ?!SlotFreed) =
    if (!event).requestId == requestId:
      done.fire()
  let contract = builder.contract
  let subscription = await contract.subscribe(SlotFreed, onEvent)
  await done.wait()
  await subscription.unsubscribe()

proc waitForTransferTo*(builder: MarketplaceBuilder, node: Node) {.async.} =
  without receiver =? await builder.testbed.api(node).getEthAddress():
    raise newException(TestbedError, "receiver does not have an eth address")
  let sender = builder.contract.address
  let done = newAsyncEvent()
  proc onEvent(event: ?!Transfer) =
    if (!event).sender == sender and (!event).receiver == receiver:
      done.fire()
  let token = await builder.token
  let subscription = await token.subscribe(Transfer, onEvent)
  await done.wait()
  await subscription.unsubscribe()
