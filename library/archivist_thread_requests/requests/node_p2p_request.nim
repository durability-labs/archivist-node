## This file contains the P2P request types that will be handled.
## CONNECT: connect to a peer by ID and/or addresses.
## CONNECTED_PEERS: get the number of connected peers.
## CONNECTED_PEER_IDS: get the list of connected peer IDs.
## FIND_PEER: find a peer by ID using DHT discovery.
## DISCONNECT: disconnect from a specific peer.

{.push raises: [].}

import std/[json, sets]
import chronos
import chronicles
import results
import questionable
import pkg/libp2p/switch as libp2p_switch
import ../../alloc

from "../../../archivist/archivist" import NodeServer
from ../../../archivist/node import ArchivistNodeRef, findPeer, switch

logScope:
  topics = "libarchivist libarchivistp2p"

type NodeP2PMsgType* = enum
  CONNECT
  CONNECTED_PEERS
  CONNECTED_PEER_IDS
  FIND_PEER
  DISCONNECT

type NodeP2PRequest* = object
  operation: NodeP2PMsgType
  peerId*: string
  addresses*: seq[string]

proc createShared*(
    T: type NodeP2PRequest, 
    op: NodeP2PMsgType, 
    peerId: string = "", 
    addresses: seq[string] = @[]
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].peerId = peerId
  ret[].addresses = addresses
  return ret

proc destroyShared(self: ptr NodeP2PRequest) =
  deallocShared(self)

proc processConnect(
    archivist: ptr NodeServer, 
    peerId: string, 
    addresses: seq[string]
): Future[Result[string, string]] {.async: (raises: []).} =
  ## Connect to a peer by ID and/or addresses.
  if archivist[].isNil:
    return err("Archivist node is not initialized")
  
  let pid = PeerId.init(peerId)
  if pid.isErr:
    return err("Invalid peer ID: " & peerId)
  
  var multiAddrs: seq[MultiAddress]
  for addr in addresses:
    let ma = MultiAddress.init(addr)
    if ma.isErr:
      continue
    multiAddrs.add(ma.get())
  
  try:
    await archivist[].archivistNode.switch().connect(pid.get(), multiAddrs)
    return ok("connected")
  except CancelledError:
    return err("Connect operation cancelled")
  except CatchableError as e:
    return err("Failed to connect: " & e.msg)

proc processConnectedPeers(
    archivist: ptr NodeServer
): Future[Result[string, string]] {.async: (raises: []).} =
  ## Get the number of connected peers.
  if archivist[].isNil:
    return err("Archivist node is not initialized")
  
  try:
    let inboundPeers = archivist[].archivistNode.switch().connectedPeers(Direction.In)
    let outboundPeers = archivist[].archivistNode.switch().connectedPeers(Direction.Out)
    let total = inboundPeers.len + outboundPeers.len
    return ok($total)
  except CatchableError as e:
    return err("Failed to get connected peers: " & e.msg)

proc processConnectedPeerIds(
    archivist: ptr NodeServer
): Future[Result[string, string]] {.async: (raises: []).} =
  if archivist[].isNil:
    return err("Archivist node is not initialized")
  
  try:
    var peerIdsSet: HashSet[string]
    let inboundPeers = archivist[].archivistNode.switch().connectedPeers(Direction.In)
    let outboundPeers = archivist[].archivistNode.switch().connectedPeers(Direction.Out)
    
    for peer in inboundPeers:
      peerIdsSet.incl($peer)
    for peer in outboundPeers:
      peerIdsSet.incl($peer)
    
    var peerIds: seq[string] = @[]
    for pid in peerIdsSet:
      peerIds.add(pid)
    
    let json = %*{"peerIds": peerIds}
    return ok($json)
  except CatchableError as e:
    return err("Failed to get connected peer IDs: " & e.msg)

proc processFindPeer(
    archivist: ptr NodeServer,
    peerId: string
): Future[Result[string, string]] {.async: (raises: []).} =
  if archivist[].isNil:
    return err("Archivist node is not initialized")
  
  if peerId == "":
    return err("Peer ID is required")
  
  let pid = PeerId.init(peerId)
  if pid.isErr:
    return err("Invalid peer ID: " & peerId)
  
  try:
    let found = await archivist[].archivistNode.findPeer(pid.get())
    if found.isNone:
      return err("Peer not found: " & peerId)
    
    var addrs: seq[string] = @[]
    let peerRecord = found.unsafeGet()
    for addrInfo in peerRecord.addresses:
      addrs.add($addrInfo.address)
    let json = %*{"peerId": peerId, "addresses": addrs}
    return ok($json)
  except CancelledError:
    return err("Find peer operation cancelled")
  except CatchableError as e:
    return err("Failed to find peer: " & e.msg)

proc processDisconnect(
    archivist: ptr NodeServer,
    peerId: string
): Future[Result[string, string]] {.async: (raises: []).} =
  if archivist[].isNil:
    return err("Archivist node is not initialized")
  
  if peerId == "":
    return err("Peer ID is required")
  
  let pid = PeerId.init(peerId)
  if pid.isErr:
    return err("Invalid peer ID: " & peerId)
  
  try:
    await archivist[].archivistNode.switch().disconnect(pid.get())
    return ok("disconnected")
  except CancelledError:
    return err("Disconnect operation cancelled")
  except CatchableError as e:
    return err("Failed to disconnect: " & e.msg)

proc process*(
    self: ptr NodeP2PRequest, archivist: ptr NodeServer
): Future[Result[string, string]] {.async: (raises: []).} =  
  defer:
    destroyShared(self)

  case self.operation
  of CONNECT:
    return await processConnect(archivist, self.peerId, self.addresses)
  of CONNECTED_PEERS:
    return await processConnectedPeers(archivist)
  of CONNECTED_PEER_IDS:
    return await processConnectedPeerIds(archivist)
  of FIND_PEER:
    return await processFindPeer(archivist, self.peerId)
  of DISCONNECT:
    return await processDisconnect(archivist, self.peerId)
