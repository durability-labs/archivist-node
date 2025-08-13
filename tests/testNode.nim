import std/os
import ./imports

importTests(currentSourcePath().parentDir() / "archivist")

{.warning[UnusedImport]: off.}
