import std/os
import std/net
import pkg/chronos
import pkg/questionable
import ./process

type Node* = ref object
  process: Process
  apiAddress: ?IpAddress
  apiPort: ?Port

func apiUrl*(node: Node): string =
  let address = node.apiAddress |? static parseIpAddress("127.0.0.1")
  let port = node.apiPort |? Port(8080)
  "http://" & $address & ":" & $port & "/api/archivist/v1"

const projectRoot = currentSourcePath().parentDir().parentDir().parentDir()
const buildDir = projectRoot / "build"

proc start*(_: type Node, arguments: seq[string]): Future[Node] {.async.} =
  let command = "./archivist"
  let process = await Process.start(command, arguments, buildDir)
  Node(process: process)

proc stop*(node: Node) {.async.} =
  await node.process.stop()
