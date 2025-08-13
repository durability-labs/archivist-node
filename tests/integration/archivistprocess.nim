import pkg/questionable
import pkg/questionable/results
import pkg/confutils
import pkg/chronicles
import pkg/chronos/asyncproc
import pkg/ethers
import pkg/libp2p
import std/os
import std/strutils
import archivist/conf
import ./archivistclient
import ./nodeprocess

export archivistclient
export chronicles
export nodeprocess

logScope:
  topics = "integration testing archivist process"

type ArchivistProcess* = ref object of NodeProcess
  client: ?ArchivistClient

method workingDir(node: ArchivistProcess): string =
  return currentSourcePath() / ".." / ".." / ".."

method executable(node: ArchivistProcess): string =
  return "build" / "archivist"

method startedOutput(node: ArchivistProcess): string =
  return "REST service started"

method processOptions(node: ArchivistProcess): set[AsyncProcessOption] =
  return {AsyncProcessOption.StdErrToStdOut}

method outputLineEndings(node: ArchivistProcess): string {.raises: [].} =
  return "\n"

method onOutputLineCaptured(node: ArchivistProcess, line: string) {.raises: [].} =
  discard

proc dataDir(node: ArchivistProcess): string =
  let config = NodeConf.load(cmdLine = node.arguments, quitOnFailure = false)
  return config.dataDir.string

proc ethAccount*(node: ArchivistProcess): Address =
  let config = NodeConf.load(cmdLine = node.arguments, quitOnFailure = false)
  without ethAccount =? config.ethAccount:
    raiseAssert "eth account not set"
  return Address(ethAccount)

proc apiUrl*(node: ArchivistProcess): string =
  let config = NodeConf.load(cmdLine = node.arguments, quitOnFailure = false)
  return "http://" & config.apiBindAddress & ":" & $config.apiPort & "/api/archivist/v1"

proc client*(node: ArchivistProcess): ArchivistClient =
  if client =? node.client:
    return client
  let client = ArchivistClient.new(node.apiUrl)
  node.client = some client
  return client

method stop*(node: ArchivistProcess) {.async.} =
  logScope:
    nodeName = node.name

  await procCall NodeProcess(node).stop()

  trace "stopping node client"
  if client =? node.client:
    await client.close()
    node.client = none ArchivistClient

method removeDataDir*(node: ArchivistProcess) =
  removeDir(node.dataDir)
