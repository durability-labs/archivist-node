import pkg/chronos
import pkg/chronos/asyncproc

type Process* = distinct AsyncProcessRef

proc start*(
  _: type Process,
  command: string,
  workingDir: string = "",
  arguments: seq[string] = @[]
): Future[Process] {.async.} =
  Process(await startProcess(command, workingDir, arguments))

proc stop*(process: Process) {.async.} =
  discard await AsyncProcessRef(process).terminateAndWaitForExit()

proc wait*(process: Process) {.async.} =
  let status = await AsyncProcessRef(process).waitForExit()
  if status != 0:
    raise newException(AsyncProcessError, "Process exit code: " & $status)
