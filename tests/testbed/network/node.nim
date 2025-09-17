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
  restApiStarted: AsyncEvent
  stdoutHandler: Future[void].Raising([])
  stderrHandler: Future[void].Raising([])

func apiUrl*(node: Node): string =
  "http://" & $node.apiAddress & ":" & $node.apiPort & "/api/archivist/v1"

proc handleStdout(node: Node) {.async:(raises:[]).} =
  let input = node.process.stdout
  try:
    while not input.atEof:
      let line = await input.readLine(sep = "\n")
      if line.contains("REST service started"):
        node.restApiStarted.fire()
      if output =? node.logFile:
        output.writeLine(line)
        output.flushFile()
  except CancelledError:
    discard
  except CatchableError as error:
    raise newException(Defect, "error handling node stdout: " & error.msg)

proc handleStderr(node: Node) {.async:(raises:[]).} =
  let input = node.process.stderr
  try:
    while not input.atEof:
      let line = await input.readLine(sep = "\n")
      if output =? node.logFile:
        output.writeLine(line)
        output.flushFile()
  except CancelledError:
    discard
  except CatchableError as error:
    raise newException(Defect, "error handling node stderr: " & error.msg)

proc start(node: Node) {.async.} =
  let command = "./archivist"
  var arguments = node.arguments
  arguments &= "--data-dir=" & $node.dataDir
  arguments &= "--api-bindaddr=" & $node.apiAddress
  arguments &= "--api-port=" & $node.apiPort
  try:
    node.process = await Process.start(command, arguments, projectRoot / "build")
  except ProcessError as error:
    raise newException(TestbedError, "unable to start node: " & error.msg, error)
  node.logFile = node.logFilename.?open(FileMode.fmAppend)
  node.restApiStarted = newAsyncEvent()
  node.stdoutHandler = node.handleStdout()
  node.stderrHandler = node.handleStderr()
  await node.restApiStarted.wait()

proc start*(
  _: type Node,
  arguments: seq[string],
  dataDir: string,
  apiAddress: IpAddress,
  apiPort: Port,
  logFile = string.none
): Future[Node] {.async.} =
  let node = Node(
    arguments: arguments,
    dataDir: dataDir,
    apiAddress: apiAddress,
    apiPort: apiPort,
    logFilename: logFile,
  )
  await node.start()
  node

proc stop*(node: Node) {.async.} =
  await node.process.stop()
  if stdoutHandler =? node.stdoutHandler:
    node.stdoutHandler = nil
    await stdoutHandler.cancelAndWait()
  if stderrHandler =? node.stderrHandler:
    node.stderrHandler = nil
    await stderrHandler.cancelAndWait()
  if logFile =? node.logFile:
    node.logFile = none File
    logFile.close()

proc restart*(node: Node) {.async.} =
  await node.stop()
  await node.start()

proc deleteDataDir*(node: Node) =
  removeDir(node.dataDir)
