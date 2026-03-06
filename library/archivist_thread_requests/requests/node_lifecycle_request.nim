## This file contains the lifecycle request type that will be handled.
## CREATE: create a new Archivist node with the provided config.toml.
## START: start the provided Archivist node.
## STOP: stop the provided Archivist node.

import std/[options, strutils, net, os]
import chronos
import chronicles
import results
import confutils
import confutils/std/net
import confutils/defs
import libp2p
import toml_serialization
import ../../../archivist/conf

import ../../alloc
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
    r: var TomlReader, val: var T
) =
  val = T(r.readValue(string))

proc readValue*(r: var TomlReader, val: var IpAddress) {.raises: [SerializationError, IOError].} =
  let s = r.readValue(string)
  try:
    val = parseIpAddress(s)
  except CatchableError:
    raise newException(SerializationError, "Invalid IP address: " & s)

proc readValue*(r: var TomlReader, val: var Port) {.raises: [SerializationError, IOError].} =
  let s = r.readValue(string)
  try:
    val = Port(parseInt(s))
  except CatchableError:
    raise newException(SerializationError, "Invalid port number: " & s)

type NodeLifecycleRequest* = object
  operation: NodeLifecycleMsgType
  configToml: cstring

proc createShared*(
    T: type NodeLifecycleRequest, op: NodeLifecycleMsgType, configToml: cstring = ""
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].configToml = configToml.alloc()
  return ret

proc destroyShared(self: ptr NodeLifecycleRequest) =
  deallocShared(self[].configToml)
  deallocShared(self)

proc createArchivist(
    configToml: cstring
): Future[Result[NodeServer, string]] {.async: (raises: []).} =
  var conf: NodeConf

  try:
    conf = NodeConf.load(
      version = nodeFullVersion,
      envVarsPrefix = "archivist",
      cmdLine = @[],
      secondarySources = proc(
          config: NodeConf, sources: auto
      ) {.gcsafe, raises: [ConfigurationError].} =
        if configToml.len > 0:
          sources.addConfigFileContent(Toml, $(configToml))
      ,
    )
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
        self.configToml
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
