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
    logFile: ?File
    stdoutHandler: Future[void].Raising([])
    stderrHandler: Future[void].Raising([])

func accounts*(hardhat: Hardhat): var seq[HardhatAccount] =
  hardhat.accounts

func jsonRpcUrl*(hardhat: Hardhat): string =
  "ws://localhost:8545"

func marketplaceAddress*(hardhat: Hardhat): string =
  "0x322813Fd9A801c5507c9de605d63CEA4f2CE6c44"

proc handleStdout*(hardhat: Hardhat) {.async:(raises:[]).} =
  let input = hardhat.process.stdout
  try:
    while not input.atEof:
      let line = await input.readLine(sep = "\n")
      if output =? hardhat.logFile:
        output.writeLine(line)
        output.flushFile()
  except CancelledError:
    discard
  except CatchableError as error:
    raise newException(Defect, "error handling hardhat stdout: " & error.msg)

proc handleStderr*(hardhat: Hardhat) {.async:(raises:[]).} =
  let input = hardhat.process.stderr
  try:
    while not input.atEof:
      let line = await input.readLine(sep = "\n")
      if output =? hardhat.logFile:
        output.writeLine(line)
        output.flushFile()
  except CancelledError:
    discard
  except CatchableError as error:
    raise newException(Defect, "error handling hardhat stderr: " & error.msg)

proc start*(_: type Hardhat, logFile = string.none): Future[Hardhat] {.async.} =
  const binDir = hardhatRoot / "node_modules" / ".bin"
  let process = await Process.start("./hardhat", @["node"], binDir)
  await sleepAsync(2.seconds)
  await npm(@["run", "mine"])
  await npm(@["run", "deploy", "--", "--network", "localhost"])
  let hardhat = Hardhat(
    process: process,
    logFile: logFile.?open(FileMode.fmAppend)
  )
  hardhat.stdoutHandler = hardhat.handleStdout()
  hardhat.stderrHandler = hardhat.handleStderr()
  hardhat

proc stop*(hardhat: Hardhat) {.async.} =
  await hardhat.process.stop()
  if stdoutHandler =? hardhat.stdoutHandler:
    hardhat.stdoutHandler = nil
    await stdoutHandler.cancelAndWait()
  if stderrHandler =? hardhat.stdoutHandler:
    hardhat.stderrHandler = nil
    await stderrHandler.cancelAndWait()
  if logFile =? hardhat.logFile:
    hardhat.logFile = none File
    logFile.close()
