import pkg/chronos
import ../../helpers/process
import ./root

proc npm*(arguments: seq[string]) {.async.} =
  await Process.execute("npm", arguments, hardhatRoot)
