import std/os
import std/sequtils

const keyDir = currentSourcePath().parentDir() / "keys"
const keyFiles = @[
  keyDir / "account0.key",
  keyDir / "account1.key",
  keyDir / "account2.key",
  keyDir / "account3.key",
  keyDir / "account4.key",
  keyDir / "account5.key",
  keyDir / "account6.key",
  keyDir / "account7.key",
  keyDir / "account8.key",
  keyDir / "account9.key",
  keyDir / "account10.key",
  keyDir / "account11.key",
  keyDir / "account12.key",
  keyDir / "account13.key",
  keyDir / "account14.key",
  keyDir / "account15.key",
  keyDir / "account16.key",
  keyDir / "account17.key",
  keyDir / "account18.key",
  keyDir / "account19.key",
]

type HardhatAccount* = object
  privateKeyFile: string

proc privateKeyFile*(account: HardhatAccount): string =
  account.privateKeyFile

const defaultHardhatAccounts* =
  keyFiles.mapIt(HardhatAccount(privateKeyFile: it))
