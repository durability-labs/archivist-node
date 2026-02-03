import std/os

for path in listDirs("vendor" / "nimble"):
  withDir(path):
    exec "git submodule update --init --recursive"
