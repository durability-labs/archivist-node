import std/os
import pkg/chronos
import ./process

type Hardhat* = ref object
  process: Process

const projectRoot = currentSourcePath().parentDir().parentDir().parentDir()
const workingDir = projectRoot / "vendor" / "archivist-contracts"

proc install*(_: type Hardhat) {.async.} =
  let process = await Process.start("npm", workingDir, @["install"])
  await process.wait()

proc start*(_: type Hardhat): Future[Hardhat] {.async.} =
  let process = await Process.start("npm", workingDir, @["start"])
  Hardhat(process: process)

proc stop*(hardhat: Hardhat) {.async.} =
  await hardhat.process.stop()
