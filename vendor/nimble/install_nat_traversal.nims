import std/os

withDir("vendor" / "nimble" / "nat_traversal"):
  exec "nimble buildBundledLibs"
