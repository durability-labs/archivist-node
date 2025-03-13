import std/os
import std/syncio
import std/json
import pkg/chronos
import pkg/questionable
import pkg/ethers
import ../error
import ../helpers/process
import ../helpers/project
import ./hardhat/account
import ./hardhat/npm

export account.HardhatAccount
export account.privateKeyFile

type Hardhat* = ref object
  process: Process
  accounts: seq[HardhatAccount] = defaultHardhatAccounts
  logFile: ?File
  snapshot: JsonNode
  stdoutHandler: Future[void].Raising([])
  stderrHandler: Future[void].Raising([])

func accounts*(hardhat: Hardhat): var seq[HardhatAccount] =
  hardhat.accounts

func jsonRpcUrl*(hardhat: Hardhat): string =
  "ws://localhost:8545"

func marketplaceAddress*(hardhat: Hardhat): string =
  "0xa85233C63b9Ee964Add6F2cffe00Fd84eb32338f"

proc installHardhat() {.async.} =
  if not dirExists(hardhatBinDir):
    await npm(@["install"])

proc runHardhat(): Future[Process] {.async.} =
  when defined(windows):
    let executable = hardhatBinDir / "hardhat.cmd"
  else:
    let executable = hardhatBinDir / "hardhat"
  try:
    await Process.start(
      executable,
      @["node"],
      workingDir = hardhatBinDir,
      environment = @{"HARDHAT_DISABLE_TELEMETRY_PROMPT": "true"},
    )
  except ProcessError as error:
    raise newException(TestbedError, "unable to start hardhat: " & error.msg, error)

proc handleStdout(hardhat: Hardhat) {.async: (raises: []).} =
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

proc handleStderr(hardhat: Hardhat) {.async: (raises: []).} =
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

proc save(hardhat: Hardhat) {.async.} =
  let provider = await JsonRpcProvider.connect(hardhat.jsonRpcUrl)
  hardhat.snapshot = await provider.send("evm_snapshot")

proc restore(hardhat: Hardhat) {.async.} =
  let provider = await JsonRpcProvider.connect(hardhat.jsonRpcUrl)
  discard await provider.send("evm_revert", @[hardhat.snapshot])

proc start*(_: type Hardhat, logFile = string.none): Future[Hardhat] {.async.} =
  await installHardhat()
  let hardhat = Hardhat()
  hardhat.process = await runHardhat()
  hardhat.logFile = logFile .? open(FileMode.fmAppend)
  hardhat.stdoutHandler = hardhat.handleStdout()
  hardhat.stderrHandler = hardhat.handleStderr()
  await sleepAsync(2.seconds)
  await npm(@["run", "mine"])
  await npm(@["run", "deploy", "--", "--network", "localhost"])
  await hardhat.save()
  hardhat

proc stop*(hardhat: Hardhat) {.async.} =
  when defined(windows):
    # kill all child processes, otherwise the nodejs process won't stop
    let id = hardhat.process.id
    await Process.execute(findExe("taskkill"), @["/pid", $id, "/T", "/F"])
  await hardhat.process.terminate()
  if stdoutHandler =? hardhat.stdoutHandler:
    hardhat.stdoutHandler = nil
    await stdoutHandler.cancelAndWait()
  if stderrHandler =? hardhat.stderrHandler:
    hardhat.stderrHandler = nil
    await stderrHandler.cancelAndWait()
  await hardhat.process.close()
  if logFile =? hardhat.logFile:
    hardhat.logFile = none File
    logFile.close()

proc reset*(hardhat: Hardhat) {.async.} =
  await hardhat.restore()
  await hardhat.save()
