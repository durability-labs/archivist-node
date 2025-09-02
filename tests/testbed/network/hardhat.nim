import std/os
import std/syncio
import pkg/chronos
import pkg/questionable
import ../helpers/process
import ./hardhat/account
import ./hardhat/npm
import ./hardhat/root

export account.HardhatAccount
export account.privateKeyFile

type
  Hardhat* = ref object
    process: Process
    accounts: seq[HardhatAccount] = defaultHardhatAccounts
    logger: Future[void].Raising([])

func accounts*(hardhat: Hardhat): var seq[HardhatAccount] =
  hardhat.accounts

func jsonRpcUrl*(hardhat: Hardhat): string =
  "ws://localhost:8545"

func marketplaceAddress*(hardhat: Hardhat): string =
  "0x322813Fd9A801c5507c9de605d63CEA4f2CE6c44"

proc start*(_: type Hardhat): Future[Hardhat] {.async.} =
  const binDir = hardhatRoot / "node_modules" / ".bin"
  let process = await Process.start("./hardhat", @["node"], binDir)
  await sleepAsync(2.seconds)
  await npm(@["run", "mine"])
  await npm(@["run", "deploy", "--", "--network", "localhost"])
  Hardhat(process: process)

proc logToFile*(hardhat: Hardhat, file: string) =
  let input = hardhat.process.stdout
  let output = open(file, FileMode.fmAppend)
  proc log {.async:(raises:[]).} =
    try:
      while not input.atEof:
        let line = await input.readLine(sep = "\n")
        output.writeLine(line)
    except CancelledError:
      output.close()
    except CatchableError as error:
      raise newException(Defect, "error writing hardhat log: " & error.msg)
  hardhat.logger = log()

proc stop*(hardhat: Hardhat) {.async.} =
  await hardhat.process.stop()
  if logger =? hardhat.logger:
    await logger.cancelAndWait()
