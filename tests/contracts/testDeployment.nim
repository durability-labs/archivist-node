import pkg/ethers
import pkg/questionable/results
import archivist/contracts/deployment
import ../asynctest

type MockProvider = ref object of Provider
  chainId*: UInt256

method getChainId*(
    provider: MockProvider
): Future[UInt256] {.async: (raises: [ProviderError, CancelledError]).} =
  return provider.chainId

suite "Deployment":
  let provider = MockProvider()

  test "looks up hardcoded marketplace address using the chain id":
    provider.chainId = 167005.u256
    let address = await provider.getMarketplaceAddress()
    check address.isSuccess
    check $(!address) == "0x948cf9291b77bd7ad84781b9047129addf1b894f"

  test "returns error for unknown networks":
    provider.chainId = 1.u256
    let address = await provider.getMarketplaceAddress()
    check address.isFailure
