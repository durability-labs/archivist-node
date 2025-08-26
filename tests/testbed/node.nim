import std/os
import pkg/chronos
import ./process

type Node* = ref object
  process: Process

const projectRoot = currentSourcePath().parentDir().parentDir().parentDir()
const workingDir = projectRoot / "build"

proc start*(_: type Node, arguments: seq[string]): Future[Node] {.async.} =
  let process = await Process.start("archivist", workingDir, arguments)
  Node(process: process)

proc stop*(node: Node) {.async.} =
  await node.process.stop()
