import std/tables
import pkg/ethers
import pkg/questionable
import pkg/questionable/results

const MarketplaceAddresses = {
  # Hardhat localhost network
  "31337": !Address.init("0x322813Fd9A801c5507c9de605d63CEA4f2CE6c44"),
  # Taiko Alpha-3 Testnet
  "167005": !Address.init("0x948CF9291b77Bd7ad84781b9047129Addf1b894F"),
  # testnet - 2025-11-14 08:21:08 - UTC
  "421614": !Address.init("0x68d043b20C0b6aBF9932357927C5032Cc916470d"),
  # Linea (Status)
  "1660990954": !Address.init("0x34F606C65869277f236ce07aBe9af0B8c88F486B"),
}.toTable

proc getMarketplaceAddress*(
    provider: Provider
): Future[?!Address] {.async: (raises: [CancelledError]).} =
  var chainId: UInt256
  try:
    chainId = await provider.getChainId()
  except EthersError as error:
    return failure error
  let network = chainId.toString(10)
  without address =? MarketplaceAddresses .? [network]:
    return failure "No known marketplace address for network " & network
  success address
