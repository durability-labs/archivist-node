import std/os
import std/strutils
import pkg/chronos
import ../../helpers/process
import ../../helpers/project
import ../../error

proc npm*(arguments: seq[string]) {.async.} =
  try:
    await Process.execute(findExe("npm"), arguments, hardhatDir)
  except ProcessError as error:
    raise newException(
      TestbedError,
      "unable to execute 'npm " & arguments.join(" ") & "': " & error.msg,
      error,
    )
