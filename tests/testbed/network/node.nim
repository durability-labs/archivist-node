import std/os
import std/net
import std/strutils
import pkg/chronos
import pkg/questionable
import ../helpers/process
import ../helpers/project
import ../error

type Node* = ref object
  process: Process
  dataDir: string
  apiAddress: IpAddress
  apiPort: Port

func apiUrl*(node: Node): string =
  "http://" & $node.apiAddress & ":" & $node.apiPort & "/api/archivist/v1"

proc start*(
  _: type Node,
  arguments: seq[string],
  dataDir: string,
  apiAddress: IpAddress,
  apiPort: Port
): Future[Node] {.async.} =
  let command = "./archivist"
  var arguments = arguments
  arguments &= "--data-dir=" & $dataDir
  arguments &= "--api-bindaddr=" & $apiAddress
  arguments &= "--api-port=" & $apiPort
  let process = await Process.start(command, arguments, projectRoot / "build")
  Node(
    process: process,
    dataDir: dataDir,
    apiAddress: apiAddress,
    apiPort: apiPort
  )

proc waitForRestApi*(node: Node): Future[Node] {.async.} =
  let stdout = node.process.stdout
  while not stdout.atEof:
    let line = await stdout.readLine(sep = "\n")
    if line.contains("REST service started"):
      return node
  raise newException(TestbedError, "node stopped unexpectedly")

proc waitForRestApi*(node: Future[Node]): Future[Node] {.async.} =
  let node = await node
  await node.waitForRestApi()

proc stop*(node: Node) {.async.} =
  await node.process.stop()

proc deleteDataDir*(node: Node) =
  removeDir(node.dataDir)
