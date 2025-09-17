import std/strutils
import pkg/chronos
import ../../helpers/process
import ../../error
import ./root

proc npm*(arguments: seq[string]) {.async.} =
  try:
    await Process.execute("npm", arguments, hardhatRoot)
  except ProcessError as error:
    raise newException(
      TestbedError,
      "unable to execute 'npm " & arguments.join(" ") & "': " & error.msg,
      error
    )
