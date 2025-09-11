import pkg/chronos
import pkg/chronos/asyncproc

type Process* = distinct AsyncProcessRef

func stdout*(process: Process): AsyncStreamReader =
  AsyncProcessRef(process).stdoutStream

proc start*(
  _: type Process,
  command: string,
  arguments: seq[string] = @[],
  workingDir: string = ""
): Future[Process] {.async.} =
  let process = await startProcess(
    command,
    workingDir,
    arguments,
    options = {AsyncProcessOption.UsePath},
    stdinHandle = AsyncProcess.Pipe(),
    stdoutHandle = AsyncProcess.Pipe(),
    stderrHandle = AsyncProcess.Pipe()
  )
  Process(process)

proc stop*(process: Process) {.async.} =
  if AsyncProcessRef(process).running.tryGet():
    AsyncProcessRef(process).terminate().tryGet()
    discard await AsyncProcessRef(process).waitForExit()

proc wait*(process: Process) {.async.} =
  let status = await AsyncProcessRef(process).waitForExit()
  if status != 0:
    raise newException(AsyncProcessError, "Process exit code: " & $status)

proc execute*(
  _: type Process,
  command: string,
  arguments: seq[string] = @[],
  workingDir: string = ""
) {.async.} =
  let process = await Process.start(command, arguments, workingDir)
  await process.wait()
