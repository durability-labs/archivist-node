import std/os
import pkg/chronos
import pkg/chronos/asyncproc

type Process* = distinct AsyncProcessRef
type ProcessError* = AsyncProcessError

func id*(process: Process): int =
  AsyncProcessRef(process).processId

func stdout*(process: Process): AsyncStreamReader =
  AsyncProcessRef(process).stdoutStream

func stderr*(process: Process): AsyncStreamReader =
  AsyncProcessRef(process).stderrStream

proc start*(
    _: type Process,
    command: string,
    arguments: seq[string] = @[],
    workingDir: string = "",
    environment: seq[(string, string)] = @{:},
): Future[Process] {.async.} =
  let environmentTable = getProcessEnvironment()
  for (key, value) in environment:
    environmentTable[key] = value
  let process = await startProcess(
    command,
    workingDir,
    arguments,
    environmentTable,
    stdinHandle = AsyncProcess.Pipe(),
    stdoutHandle = AsyncProcess.Pipe(),
    stderrHandle = AsyncProcess.Pipe(),
  )
  Process(process)

proc terminate*(process: Process) {.async.} =
  if AsyncProcessRef(process).running.tryGet():
    if AsyncProcessRef(process).terminate().isOk:
      discard await AsyncProcessRef(process).waitForExit()

proc wait*(process: Process) {.async.} =
  let status = await AsyncProcessRef(process).waitForExit()
  await AsyncProcessRef(process).closeWait()
  if status != 0:
    raise newException(AsyncProcessError, "Process exit code: " & $status)

proc close*(process: Process) {.async.} =
  await AsyncProcessRef(process).closeWait()

proc execute*(
    _: type Process,
    command: string,
    arguments: seq[string] = @[],
    workingDir: string = "",
) {.async.} =
  let process = await Process.start(command, arguments, workingDir)
  await process.wait()
  await process.close()
