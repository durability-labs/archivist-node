import std/tables
import pkg/ethers
import pkg/questionable
import pkg/questionable/results

const MarketplaceAddresses = {
  # Hardhat localhost network
  "31337": !Address.init("0xa85233C63b9Ee964Add6F2cffe00Fd84eb32338f"),
  # Taiko Alpha-3 Testnet
  "167005": !Address.init("0x948CF9291b77Bd7ad84781b9047129Addf1b894F"),
  # testnet - 2026-06-24 13:14:44 - UTC
  "421614": !Address.init("0xC46FC5c710F0Eddfd91Fb95843d3c6F6C8b00EA2"),
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
