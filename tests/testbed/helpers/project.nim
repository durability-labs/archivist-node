import std/os

const projectRoot* =
  currentSourcePath()
    .parentDir()
    .parentDir()
    .parentDir()
    .parentDir()

const projectLogDir* = projectRoot / "logs"
const projectBuildDir* = projectRoot / "build"
const hardhatDir* = projectRoot / "vendor" / "archivist-contracts"
const hardhatBinDir* = hardhatDir / "node_modules" / ".bin"
