import std/json
import std/os
import std/options
import std/strutils
import std/times
import pkg/ethers
import pkg/archivist/marketplace/contracts/marketplacecontract
import ../testbed/helpers/project

const marketAddressEnvName = "ARCHIVIST_MARKET_ADDRESS"
const marketPlaceholderName = "Marketplace#Marketplace"
const testMarketPlaceholderName = "Marketplace#TestMarketplace"

proc latestDeployedAddressesPath(): ?!string =
  let deploymentsDir = hardhatDir / "ignition" / "deployments"
  if not dirExists(deploymentsDir):
    return failure(
      newException(IOError, "no ignition deployments directory: " & deploymentsDir)
    )

  var newestPath: string
  var newestTime = 0.int64
  for kind, path in walkDir(deploymentsDir):
    if kind != PathComponent.pcDir or not path.startsWith(deploymentsDir / "chain-"):
      continue

    let addressesPath = path / "deployed_addresses.json"
    if not fileExists(addressesPath):
      continue

    let modified = getLastModificationTime(addressesPath).toUnix
    if modified > newestTime:
      newestTime = modified
      newestPath = addressesPath

  if newestPath.len == 0:
    return failure(
      newException(
        IOError,
        "no deployed_addresses.json found under " & deploymentsDir,
      )
    )

  success(newestPath)

proc deployedAddress(placeholder: string): ?!Address =
  without addressesPath =? latestDeployedAddressesPath(), err:
    return failure(err)

  var data: JsonNode
  try:
    data = parseFile(addressesPath)
  except CatchableError as error:
    return failure(
      newException(IOError, "unable to parse " & addressesPath & ": " & error.msg)
    )

  if placeholder notin data:
    return failure(
      newException(
        ValueError,
        "missing deployed address for " & placeholder & " in " & addressesPath,
      )
    )

  let address = data[placeholder].getStr()
  without parsed =? Address.init(address):
    return failure(
      newException(
        ValueError,
        "invalid deployed address for " & placeholder & ": " & address,
      )
    )

  success(parsed)

proc address*(_: type MarketplaceContract, dummyVerifier = false): Address =
  if existsEnv(marketAddressEnvName):
    without address =? Address.init(getEnv(marketAddressEnvName)):
      raiseAssert "Invalid env. variable marketplace contract address"

    return address

  let placeholder =
    if dummyVerifier: testMarketPlaceholderName else: marketPlaceholderName
  without address =? deployedAddress(placeholder), err:
    raiseAssert "Unable to determine deployed marketplace address: " & err.msg

  address
