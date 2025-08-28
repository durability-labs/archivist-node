import std/os
import pkg/chronos
import pkg/questionable
import ./process
import ./hardhat/account
import ./hardhat/npm
import ./hardhat/root

export account.HardhatAccount
export account.privateKeyFile

type
  Hardhat* = ref object
    process: Process
    accounts: seq[HardhatAccount] = defaultHardhatAccounts

func accounts*(hardhat: Hardhat): var seq[HardhatAccount] =
  hardhat.accounts

func jsonRpcUrl*(hardhat: Hardhat): string =
  "ws://localhost:8545"

func marketplaceAddress*(hardhat: Hardhat): string =
  "0x322813Fd9A801c5507c9de605d63CEA4f2CE6c44"

proc install*(_: type Hardhat) {.async.} =
  await npm(@["install"])

proc start*(_: type Hardhat): Future[Hardhat] {.async.} =
  const binDir = hardhatRoot / "node_modules" / ".bin"
  let process = await Process.start("./hardhat", @["node"], binDir)
  await sleepAsync(2.seconds)
  await npm(@["run", "mine"])
  await npm(@["run", "deploy", "--", "--network", "localhost"])
  Hardhat(process: process)

proc stop*(hardhat: Hardhat) {.async.} =
  await hardhat.process.stop()
