import std/os
import pkg/chronos
import ./process

type Node* = ref object
  process: Process

const projectRoot = currentSourcePath().parentDir().parentDir().parentDir()
const buildDir = projectRoot / "build"

proc start*(_: type Node, arguments: seq[string]): Future[Node] {.async.} =
  let command = "./archivist"
  let process = await Process.start(command, arguments, buildDir)
  Node(process: process)

proc stop*(node: Node) {.async.} =
  await node.process.stop()
