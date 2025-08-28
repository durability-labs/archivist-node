import pkg/chronos
import pkg/ethers
import pkg/questionable
import ../testbed
import ../hardhat
import ../contract
import ../error

type MarketplaceBuilder = ref object
  testbed: Testbed
  contractInstance: ?MarketplaceContract

func marketplace*(testbed: Testbed): MarketplaceBuilder =
  MarketplaceBuilder(testbed: testbed)

proc contract(builder: MarketplaceBuilder): MarketplaceContract =
  without var contract =? builder.contractInstance:
    without hardhat =? builder.testbed.hardhatInstance:
      raise newException(TestbedError, "hardhat is not running")
    without address =? Address.init(hardhat.marketplaceAddress):
      raise newException(TestbedError, "invalid marketplace address")
    without var provider =? builder.testbed.providerInstance:
      provider = JsonRpcProvider.new(hardhat.jsonRpcUrl)
      builder.testbed.providerInstance = some provider
    contract = MarketplaceContract.new(address, provider)
    builder.contractInstance = some contract
  contract
