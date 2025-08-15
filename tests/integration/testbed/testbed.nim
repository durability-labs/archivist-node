import ../hardhatprocess
import ../archivistprocess

type Testbed* = ref object
  hardhatProcess: ?HardhatProcess
  nodeProcesses: seq[ArchivistProcess]

func hardhatProcess*(testbed: Testbed): ?HardhatProcess =
  testbed.hardhatProcess

func `hardhatProcess=`*(testbed: Testbed, process: ?HardhatProcess) =
  testbed.hardhatProcess = process

func nodeProcesses*(testbed: Testbed): var seq[ArchivistProcess] =
  testbed.nodeProcesses
