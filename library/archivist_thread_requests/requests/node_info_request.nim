## This file contains the node info request types that will be handled.
## VERSION: get the Archivist version.
## REVISION: get the Archivist revision.
## REPO: get the repo (data directory) path.
## PEERID: get the node's peer ID.
## SPR: get the node's Signed Peer Record.

{.push raises: [].}

import std/options
import chronos
import chronicles
import results
import pkg/libp2p/switch as libp2p_switch
import ../../alloc

from "../../../archivist/archivist" import NodeServer
from ../../../archivist/node import ArchivistNodeRef, switch, discovery

# TODO: Should this really be hardcoded here?
const archivistVersion* = "0.1.0"
const archivistRevision* = "unknown"

logScope:
  topics = "libarchivist libarchivistinfo"

type NodeInfoMsgType* = enum
  VERSION
  REVISION
  REPO
  PEERID
  SPR

type NodeInfoRequest* = object
  operation: NodeInfoMsgType

proc createShared*(T: type NodeInfoRequest, op: NodeInfoMsgType): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  return ret

proc destroyShared(self: ptr NodeInfoRequest) =
  deallocShared(self)

proc process*(
    self: ptr NodeInfoRequest, archivist: ptr NodeServer
): Future[Result[string, string]] {.async: (raises: []).} =
  defer:
    destroyShared(self)

  case self.operation
  of VERSION:
    return ok(archivistVersion)
  of REVISION:
    return ok(archivistRevision)
  of REPO:
    # TODO: Get actual repo path from config
    return ok("")
  of PEERID:
    if archivist[].isNil:
      return err("Archivist node is not initialized")
    return ok($archivist[].archivistNode.switch.peerInfo.peerId)
  of SPR:
    if archivist[].isNil:
      return err("Archivist node is not initialized")
    let spr = archivist[].archivistNode.discovery().dhtRecord
    if spr.isNone:
      return err("Failed to get SPR: no SPR record found")
    return ok($spr.get())
