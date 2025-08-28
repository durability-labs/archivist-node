import std/os

const projectRoot = currentSourcePath().parentDir().parentDir().parentDir().parentDir()
const hardhatRoot* = projectRoot / "vendor" / "archivist-contracts"
