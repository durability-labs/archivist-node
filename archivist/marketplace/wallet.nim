import pkg/ethers
import pkg/questionable/results
import ../utils/fileutils

proc loadWallet*(keyfile: string, provider: Provider): ?!Wallet =
  without isSecure =? checkSecureFile(keyFile):
    return
      failure "Could not check file permissions: does Ethereum private key file exist?"
  if not isSecure:
    return failure "Ethereum private key file does not have safe file permissions"
  without key =? keyFile.readAllChars():
    return failure "Unable to read Ethereum private key file"
  without wallet =? Wallet.new(key.strip(), provider):
    return failure "Invalid Ethereum private key in file"
  success wallet
