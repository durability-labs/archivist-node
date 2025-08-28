import pkg/chronos
import ../process
import ./root

proc npm*(arguments: seq[string]) {.async.} =
  await Process.execute("npm", arguments, hardhatRoot)
