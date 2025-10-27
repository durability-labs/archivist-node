import std/os
import std/net
import std/strutils
import pkg/chronos
import pkg/questionable
import ../error
import ../helpers/process
import ../helpers/project

type Node* = ref object
  process: Process
  arguments: seq[string]
  dataDir: string
  apiAddress: IpAddress
  apiPort: Port
  logFilename: ?string
  logFile: ?File
  waitForOutput: ?string
  stdout: AsyncQueue[string]
  stderr: AsyncQueue[string]
  stdoutHandler: Future[void].Raising([])
  stderrHandler: Future[void].Raising([])

func apiUrl*(node: Node): string =
  "http://" & $node.apiAddress & ":" & $node.apiPort & "/api/archivist/v1"

proc waitForOutput(node: Node) {.async.} =
  without output =? node.waitForOutput:
    return
  while not (node.process.stdout.atEof and node.stdout.empty):
    let line = await node.stdout.get()
    if output in line:
      return
  raise newException(TestbedError, "node did not output '" & output & "'")

proc handleStdout(node: Node) {.async: (raises: []).} =
  let input = node.process.stdout
  try:
    while not input.atEof:
      let line = await input.readLine(sep = "\n")
      node.stdout.putNoWait(line)
      if output =? node.logFile:
        output.writeLine(line)
        output.flushFile()
  except CancelledError:
    discard
  except CatchableError as error:
    raise newException(Defect, "error handling node stdout: " & error.msg)

proc handleStderr(node: Node) {.async: (raises: []).} =
  let input = node.process.stderr
  try:
    while not input.atEof:
      let line = await input.readLine(sep = "\n")
      node.stderr.putNoWait(line)
      if output =? node.logFile:
        output.writeLine(line)
        output.flushFile()
  except CancelledError:
    discard
  except CatchableError as error:
    raise newException(Defect, "error handling node stderr: " & error.msg)

proc start(node: Node) {.async.} =
  let command = projectBuildDir / "integration-test" / "archivist-for-testing"
  var arguments = node.arguments
  arguments &= "--data-dir=" & $node.dataDir
  arguments &= "--api-bindaddr=" & $node.apiAddress
  arguments &= "--api-port=" & $node.apiPort
  try:
    node.process = await Process.start(command, arguments)
  except ProcessError as error:
    raise newException(TestbedError, "unable to start node: " & error.msg, error)
  node.logFile = node.logFilename .? open(FileMode.fmAppend)
  node.stdout = newAsyncQueue[string]()
  node.stderr = newAsyncQueue[string]()
  node.stdoutHandler = node.handleStdout()
  node.stderrHandler = node.handleStderr()
  await node.waitForOutput()

proc start*(
    _: type Node,
    arguments: seq[string],
    dataDir: string,
    apiAddress: IpAddress,
    apiPort: Port,
    logFile = string.none,
    waitForOutput = string.none,
): Future[Node] {.async.} =
  let node = Node(
    arguments: arguments,
    dataDir: dataDir,
    apiAddress: apiAddress,
    apiPort: apiPort,
    logFilename: logFile,
    waitForOutput: waitForOutput,
  )
  await node.start()
  node

proc stop*(node: Node) {.async.} =
  await node.process.terminate()
  if stdoutHandler =? node.stdoutHandler:
    node.stdoutHandler = nil
    await stdoutHandler.cancelAndWait()
  if stderrHandler =? node.stderrHandler:
    node.stderrHandler = nil
    await stderrHandler.cancelAndWait()
  await node.process.close()
  if logFile =? node.logFile:
    node.logFile = none File
    logFile.close()

proc restart*(node: Node) {.async.} =
  await node.stop()
  await node.start()

proc deleteDataDir*(node: Node) =
  removeDir(node.dataDir)
