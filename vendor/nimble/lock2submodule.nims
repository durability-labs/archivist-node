# Reads nimble package versions from a nimble.lock file, and creates git
# submodules in the vendor/nimble directory for those package versions.

import std/os
import std/json

let packages = parseJson(readFile("nimble.lock"))
for package in packages["packages"].keys:
  let url = packages["packages"][package]["url"].getStr()
  let commit = packages["packages"][package]["vcsRevision"].getStr()
  exec "git submodule add -f " & url & " " & "vendor" / "nimble" / package
  withDir("vendor" / "nimble" / package):
    exec("git checkout " & commit)
