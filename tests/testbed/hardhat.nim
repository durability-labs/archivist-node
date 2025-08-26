import std/os
import pkg/chronos
import ./process

type Hardhat* = ref object
  process: Process

const projectRoot = currentSourcePath().parentDir().parentDir().parentDir()
const hardhatRoot = projectRoot / "vendor" / "archivist-contracts"

proc npm(arguments: seq[string]) {.async.} =
  await Process.execute("npm", arguments, hardhatRoot)

proc install*(_: type Hardhat) {.async.} =
  await npm(@["install"])

proc start*(_: type Hardhat): Future[Hardhat] {.async.} =
  const binDir = hardhatRoot / "node_modules" / ".bin"
  let process = await Process.start("./hardhat", @["node"], binDir)
  await sleepAsync(2.seconds)
  await npm(@["run", "mine"])
  await npm(@["run", "deploy", "--", "--network", "localhost"])
  Hardhat(process: process)

proc stop*(hardhat: Hardhat) {.async.} =
  await hardhat.process.stop()
