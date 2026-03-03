## This file contains the lifecycle request type that will be handled.
## CREATE: create a new Archivist node with the provided config.json.
## START: start the provided Archivist node.
## STOP: stop the provided Archivist node.

import std/[options, json, strutils, net, os]
import chronos
import chronicles
import results
import confutils
import confutils/std/net
import confutils/defs
import libp2p
import libp2p/routing_record
import json_serialization
import json_serialization/std/[options, net]
import ../../../archivist/conf

import ../../alloc
import ../../../archivist/conf
import ../../../archivist/utils
import ../../../archivist/utils/[keyutils, fileutils]
import ../../../archivist/units

from ../../../archivist/archivist import NodeServer, new, start, stop
from ../../../archivist/conf import nodeFullVersion

logScope:
  topics = "libarchivist libarchivistlifecycle"

type NodeLifecycleMsgType* = enum
  CREATE
  START
  STOP

proc readValue*[T: InputFile | InputDir | OutPath | OutDir | OutFile](
    r: var JsonReader, val: var T
) {.raises: [SerializationError, IOError].} =
  val = T(r.readValue(string))

proc readValue*(r: var JsonReader, val: var MultiAddress) {.raises: [SerializationError, IOError].} =
  let addrStr = r.readValue(string)
  let res = MultiAddress.init(addrStr)
  if res.isErr:
    raise
      newException(SerializationError, "Cannot parse MultiAddress: " & addrStr)
  val = res.get()

proc readValue*(r: var JsonReader, val: var NatConfig) {.raises: [SerializationError, ValueError, IOError].} =
  try:
    val = NatConfig.parseCmdArg(r.readValue(string))
  except ValueError as e:
    raise
      newException(SerializationError, "Cannot parse the NAT config: " & e.msg)

proc readValue*(r: var JsonReader, val: var SignedPeerRecord) {.raises: [SerializationError, IOError].} =
  let uri = r.readValue(string)
  if not val.fromURI(uri):
    raise
      newException(SerializationError, "Cannot parse the signed peer record: " & uri)

proc readValue*(r: var JsonReader, val: var ThreadCount) {.raises: [SerializationError, IOError].} =
  val = ThreadCount(r.readValue(int))

proc readValue*(r: var JsonReader, val: var NBytes) {.raises: [SerializationError, IOError].} =
  val = NBytes(r.readValue(int))

proc readValue*(r: var JsonReader, val: var Duration) {.raises: [SerializationError, IOError].} =
  var dur: Duration
  let input = r.readValue(string)
  let count = parseDuration(input, dur)
  if count == 0:
    raise newException(SerializationError, "Cannot parse the duration: " & input)
  val = dur

type NodeLifecycleRequest* = object
  operation: NodeLifecycleMsgType
  configJson: cstring

proc createShared*(
    T: type NodeLifecycleRequest, op: NodeLifecycleMsgType, configJson: cstring = ""
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].configJson = configJson.alloc()
  return ret

proc destroyShared(self: ptr NodeLifecycleRequest) =
  deallocShared(self[].configJson)
  deallocShared(self)

proc createArchivist(
    configJson: cstring
): Future[Result[NodeServer, string]] {.async: (raises: []).} =
  var conf: NodeConf

  try:
    # TODO: Fix configuration loading serialization issues, remove hardcoded stuff
    conf = default(NodeConf)
    conf.logLevel = "info"
    conf.dataDir = OutDir(defaultDataDir())
    conf.netPrivKeyFile = "key"
    conf.maxPeers = 160
    conf.agentString = "Archivist Node"
    conf.numThreads = ThreadCount(0)
    conf.discoveryPort = Port(8090)
    
    conf.listenAddrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/0").expect("Should init multiaddress")]
    
    conf.apiBindAddress = "127.0.0.1"
    conf.apiPort = Port(8080)
    conf.storageQuota = DefaultQuotaBytes
    conf.blockTtl = DefaultBlockTtl
    conf.blockMaintenanceInterval = DefaultBlockInterval
    conf.blockMaintenanceNumberOfBlocks = DefaultNumBlocksPerInterval
    
    let dataDir = string(conf.dataDir)
    if not dirExists(dataDir):
      try:
        createDir(dataDir)
      except CatchableError as e:
        # TODO: Should we really ignore the directory creation failure?
        discard
  except ConfigurationError as e:
    return err("Failed to create Archivist: unable to load configuration: " & e.msg)

  conf.setupLogging()

  try:
    {.gcsafe.}:
      updateLogLevel(conf.logLevel)
  except ValueError as err:
    return err("Failed to create Archivist: invalid value for log level: " & err.msg)

  conf.setupMetrics()

  if not (checkAndCreateDataDir((conf.dataDir).string)):
    return err(
      "Failed to create Archivist: unable to access/create data folder or data folder's permissions are insecure."
    )

  if not (checkAndCreateDataDir((conf.dataDir / "repo"))):
    return err(
      "Failed to create Archivist: unable to access/create data folder or data folder's permissions are insecure."
    )

  let keyPath =
    if isAbsolute(conf.netPrivKeyFile):
      conf.netPrivKeyFile
    else:
      conf.dataDir / conf.netPrivKeyFile
  let privateKey = setupKey(keyPath)
  if privateKey.isErr:
    return err("Failed to create Archivist: unable to get the private key.")
  let pk = privateKey.get()

  let archivist =
    try:
      NodeServer.new(conf, pk)
    except Exception as exc:
      return err("Failed to create Archivist: " & exc.msg)

  return ok(archivist)

proc process*(
    self: ptr NodeLifecycleRequest, archivist: ptr NodeServer
): Future[Result[string, string]] {.async: (raises: []).} =
  defer:
    destroyShared(self)

  case self.operation
  of CREATE:
    archivist[] = (
      await createArchivist(
        self.configJson
      )
    ).valueOr:
      error "Failed to CREATE.", error = error
      return err($error)
  of START:
    try:
      await archivist[].start()
    except Exception as e:
      error "Failed to START.", error = e.msg
      return err(e.msg)
  of STOP:
    try:
      await archivist[].stop()
    except Exception as e:
      error "Failed to STOP.", error = e.msg
      return err(e.msg)
  return ok("")
