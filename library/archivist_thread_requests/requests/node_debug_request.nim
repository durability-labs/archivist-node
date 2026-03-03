## This file contains the debug request types that will be handled.
## DEBUG: get debug information about the node.
## LOG_LEVEL: set the log level at runtime.
## CONNECTED_PEERS: get the number of connected peers.
## CONNECTED_PEER_IDS: get the list of connected peer IDs.
## FIND_PEER: find a peer by ID using DHT discovery.
## PEER_INFO: get information about a specific peer.
## DISCONNECT: disconnect from a specific peer.

# TODO: Debug requests processing still need to be implemented

{.push raises: [].}

import std/json
import std/strutils
import chronos
import chronicles
import results
import libp2p
import ../../alloc
import ../../ffi_types

from "../../../archivist/archivist" import NodeServer
from ../../../archivist/node import switch, discovery

logScope:
  topics = "libarchivist libarchivistdebug"

type NodeDebugMsgType* = enum
  DEBUG
  LOG_LEVEL
  CONNECTED_PEERS
  CONNECTED_PEER_IDS
  FIND_PEER
  PEER_INFO
  DISCONNECT

type NodeDebugRequest* = object
  operation: NodeDebugMsgType
  data: cstring

proc createShared*(
    T: type NodeDebugRequest, op: NodeDebugMsgType, data: cstring = ""
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].data = data.alloc()
  return ret

proc destroyShared(self: ptr NodeDebugRequest) =
  deallocShared(self[].data)
  deallocShared(self)

proc process*(
    self: ptr NodeDebugRequest, archivist: ptr NodeServer
): Future[Result[string, string]] {.async: (raises: []).} =
  defer:
    destroyShared(self)

  case self.operation
  of DEBUG:
    var debugInfo = %*{
      "version": "0.1.0",
      "status": "running"
    }
    return ok($debugInfo)
    
  of LOG_LEVEL:
    let level = $self.data
    info "Log level change requested", level = level
    return ok("ok")
    
  of CONNECTED_PEERS:
    if archivist[].isNil:
      return err("Archivist node is not initialized")
    return ok("0")
    
  of CONNECTED_PEER_IDS:
    if archivist[].isNil:
      return err("Archivist node is not initialized")
    let json = %*{"peerIds": []}
    return ok($json)
    
  of FIND_PEER:
    if archivist[].isNil:
      return err("Archivist node is not initialized")
    let peerIdStr = $self.data
    if peerIdStr == "":
      return err("Peer ID is required")
    return ok("{}")
    
  of PEER_INFO:
    if archivist[].isNil:
      return err("Archivist node is not initialized")
    let peerIdStr = $self.data
    if peerIdStr == "":
      return err("Peer ID is required")
    return ok("{}")
    
  of DISCONNECT:
    if archivist[].isNil:
      return err("Archivist node is not initialized")
    let peerIdStr = $self.data
    if peerIdStr == "":
      return err("Peer ID is required")
    return ok("disconnected")
