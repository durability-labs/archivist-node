# Adds paths of the packages in vendor/nimble to the compiler.
# Include this file in config.nims

import std/os

for path in listDirs("vendor" / "nimble"):
  let (_, name, _) = path.splitFile()
  if name in ["lrucache", "zippy"]:
    switch("path", path / "src")
  else:
    switch("path", path)
