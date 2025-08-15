import pkg/chronos
import ../archivistprocess
import ./testbed

type NodeBuilder = ref object
  testbed: Testbed
  arguments: seq[string]

func node*(testbed: Testbed): NodeBuilder =
  NodeBuilder(testbed: testbed)

func provider*(builder: NodeBuilder): NodeBuilder =
  builder.arguments.add("--persistence")
  builder

func failProofs*(builder: NodeBuilder, every: uint): NodeBuilder =
  builder.arguments.add("--simulate-proof-failures " & $every)
  builder

proc start*(builder: NodeBuilder) {.async.} =
  let process = await ArchivistProcess.startNode(args = builder.arguments, name = "node")
  builder.testbed.nodeProcesses.add(process)

type NodesCommand = ref object
  testbed: Testbed

func nodes*(testbed: Testbed): NodesCommand =
  NodesCommand(testbed: testbed)

proc stop*(command: NodesCommand) {.async.} =
  for process in command.testbed.nodeProcesses:
    await process.stop()