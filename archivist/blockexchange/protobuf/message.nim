# Protocol of data exchange between nodes
# and Protobuf encoder/decoder for these messages.
#
# Eventually all this code should be auto-generated from message.proto.
import std/sugar

import pkg/libp2p/protobuf/minprotobuf
import pkg/libp2p/cid

import pkg/questionable

import ../../units

import ../../merkletree
import ../../blocktype

const
  MaxBlockSize* = 100.MiBs.uint
  MaxMessageSize* = 100.MiBs.uint

type
  WantType* = enum
    WantBlock = 0
    WantHave = 1

  WantListEntry* = object
    address*: BlockAddress
    priority*: int32 # The priority (normalized). default to 1
    cancel*: bool # Whether this revokes an entry
    wantType*: WantType # Note: defaults to enum 0, ie Block
    sendDontHave*: bool # Note: defaults to false
    inFlight*: bool # Whether block sending is in progress. Not serialized.

  WantList* = object
    entries*: seq[WantListEntry] # A list of wantList entries
    full*: bool # Whether this is the full wantList. default to false

  BlockDelivery* = object
    blk*: Block
    address*: BlockAddress
    proof*: ?ArchivistProof # Present only if `address.leaf` is true

  BlockPresenceType* = enum
    Have = 0
    DontHave = 1

  BlockPresence* = object
    address*: BlockAddress
    `type`*: BlockPresenceType

  Message* = object
    wantList*: WantList
    payload*: seq[BlockDelivery]
    blockPresences*: seq[BlockPresence]
    pendingBytes*: uint

template messageKind*(msg: Message): string =
  if msg.payload.len > 0:
    "blocks"
  elif msg.blockPresences.len > 0:
    "presence"
  elif msg.wantList.entries.len > 0:
    "wantlist"
  else:
    "other"

#
# Encoding Message into seq[byte] in Protobuf format
#

proc write*(pb: var ProtoBuffer, field: int, value: sink BlockAddress) =
  var ipb = initProtoBuffer()
  ipb.write(1, value.leaf.uint)
  if value.leaf:
    ipb.write(2, value.treeCid.data.buffer)
    ipb.write(3, value.index.uint64)
  else:
    ipb.write(4, value.cid.data.buffer)
  ipb.finish()
  pb.write(field, ipb.buffer)

proc write*(pb: var ProtoBuffer, field: int, value: sink WantListEntry) =
  var ipb = initProtoBuffer()
  ipb.write(1, value.address)
  ipb.write(2, value.priority.uint64)
  ipb.write(3, value.cancel.uint)
  ipb.write(4, value.wantType.uint)
  ipb.write(5, value.sendDontHave.uint)
  ipb.finish()
  pb.write(field, ipb.buffer)

proc write*(pb: var ProtoBuffer, field: int, value: sink WantList) =
  var ipb = initProtoBuffer()
  for v in value.entries.mitems:
    ipb.write(1, move v)
  ipb.write(2, value.full.uint)
  ipb.finish()
  pb.write(field, ipb.buffer)

proc write*(pb: var ProtoBuffer, field: int, value: sink BlockDelivery) =
  var ipb = initProtoBuffer()
  let isLeaf = value.address.leaf
  ipb.write(1, value.blk.cid.data.buffer)
  ipb.write(2, value.blk.data)
  ipb.write(3, value.address)
  if isLeaf:
    if proof =? value.proof:
      ipb.write(4, proof.encode())
  ipb.finish()
  pb.write(field, ipb.buffer)

proc write*(pb: var ProtoBuffer, field: int, value: sink BlockPresence) =
  var ipb = initProtoBuffer()
  ipb.write(1, value.address)
  ipb.write(2, value.`type`.uint)
  ipb.finish()
  pb.write(field, ipb.buffer)

proc encode*(value: sink Message): seq[byte] =
  var ipb = initProtoBuffer()
  # Pre-size the buffer: repeated payload blocks dominate (tens of MB).
  # Without reserve capacity the buffer grows by doubling, reallocating
  # and copying ~2x the final size during encode.
  var estimate =
    64 + 16 + value.wantList.entries.len * 64 + value.blockPresences.len * 64
  for i in 0 ..< value.payload.len:
    estimate += value.payload[i].blk.data.len + 512
  ipb.buffer = newSeqOfCap[byte](estimate)
  ipb.write(1, value.wantList)
  for v in value.payload.mitems:
    ipb.write(3, move v)
  for v in value.blockPresences.mitems:
    ipb.write(4, move v)
  ipb.write(5, value.pendingBytes)
  ipb.finish()
  ipb.buffer

#
# Decoding Message from seq[byte] in Protobuf format
#
proc decode*(_: type BlockAddress, pb: sink ProtoBuffer): ProtoResult[BlockAddress] =
  var
    value: BlockAddress
    leaf: bool
    field: uint64
    cidBuf = newSeq[byte]()

  if ?pb.getField(1, field):
    leaf = bool(field)

  if leaf:
    var
      treeCid: Cid
      index: Natural
    if ?pb.getField(2, cidBuf):
      treeCid = ?Cid.init(cidBuf).mapErr(x => ProtoError.IncorrectBlob)
    if ?pb.getField(3, field):
      index = field
    value = BlockAddress(leaf: true, treeCid: treeCid, index: index)
  else:
    var cid: Cid
    if ?pb.getField(4, cidBuf):
      cid = ?Cid.init(cidBuf).mapErr(x => ProtoError.IncorrectBlob)
    value = BlockAddress(leaf: false, cid: cid)

  ok(value)

proc decode*(_: type WantListEntry, pb: sink ProtoBuffer): ProtoResult[WantListEntry] =
  var
    value = WantListEntry()
    field: uint64
    ipb: ProtoBuffer
  if ?pb.getField(1, ipb):
    value.address = ?BlockAddress.decode(ipb)
  if ?pb.getField(2, field):
    value.priority = int32(field)
  if ?pb.getField(3, field):
    value.cancel = bool(field)
  if ?pb.getField(4, field):
    value.wantType = WantType(field)
  if ?pb.getField(5, field):
    value.sendDontHave = bool(field)
  ok(value)

proc decode*(_: type WantList, pb: sink ProtoBuffer): ProtoResult[WantList] =
  var
    value = WantList()
    field: uint64
    sublist: seq[seq[byte]]
  if ?pb.getRepeatedField(1, sublist):
    for item in sublist.mitems:
      value.entries.add(?WantListEntry.decode(initProtoBuffer(move item)))
  if ?pb.getField(2, field):
    value.full = bool(field)
  ok(value)

proc decode*(_: type BlockDelivery, pb: sink ProtoBuffer): ProtoResult[BlockDelivery] =
  var
    value = BlockDelivery()
    dataBuf = newSeq[byte]()
    cidBuf = newSeq[byte]()
    cid: Cid
    ipb: ProtoBuffer

  if ?pb.getField(1, cidBuf):
    cid = ?Cid.init(cidBuf).mapErr(x => ProtoError.IncorrectBlob)
  if ?pb.getField(2, dataBuf):
    value.blk =
      ?Block.new(cid, dataBuf, verify = true).mapErr(x => ProtoError.IncorrectBlob)
  if ?pb.getField(3, ipb):
    value.address = ?BlockAddress.decode(ipb)

  if value.address.leaf:
    var proofBuf = newSeq[byte]()
    if ?pb.getField(4, proofBuf):
      let proof =
        ?(ArchivistProof.decode(proofBuf).mapErr(x => ProtoError.IncorrectBlob))
      value.proof = proof.some
    else:
      value.proof = ArchivistProof.none
  else:
    value.proof = ArchivistProof.none

  ok(value)

proc decode*(_: type BlockPresence, pb: sink ProtoBuffer): ProtoResult[BlockPresence] =
  var
    value = BlockPresence()
    field: uint64
    ipb: ProtoBuffer
  if ?pb.getField(1, ipb):
    value.address = ?BlockAddress.decode(ipb)
  if ?pb.getField(2, field):
    value.`type` = BlockPresenceType(field)
  ok(value)

proc decode*(_: type Message, msg: sink seq[byte]): ProtoResult[Message] =
  var
    value = Message()
    pb = initProtoBuffer(move msg)
    ipb: ProtoBuffer
    sublist: seq[seq[byte]]
  if ?pb.getField(1, ipb):
    value.wantList = ?WantList.decode(ipb)
  if ?pb.getRepeatedField(3, sublist):
    for item in sublist.mitems:
      value.payload.add(?BlockDelivery.decode(initProtoBuffer(move item)))
  if ?pb.getRepeatedField(4, sublist):
    for item in sublist.mitems:
      value.blockPresences.add(?BlockPresence.decode(initProtoBuffer(move item)))
  discard ?pb.getField(5, value.pendingBytes)
  ok(value)
