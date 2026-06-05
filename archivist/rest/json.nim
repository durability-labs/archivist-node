import pkg/questionable
import pkg/stew/byteutils
import pkg/stew/bitseqs
import pkg/libp2p
import pkg/archivistdht/discv5/node as dn
import pkg/archivistdht/discv5/routing_table as rt
import ../marketplace
import ../utils/json
import ../manifest
import ../stores/repostore/types
import ../units
import ../clock
import std/sequtils

export json

type
  StorageRequestParams* = object
    duration* {.serialize.}: StorageDuration
    proofProbability* {.serialize.}: UInt256
    pricePerBytePerSecond* {.serialize.}: TokensPerSecond
    collateralPerByte* {.serialize.}: Tokens
    expiry* {.serialize.}: StorageDuration
    nodes* {.serialize.}: ?uint
    tolerance* {.serialize.}: ?uint

  RestPurchase* = object
    requestId* {.serialize.}: RequestId
    request* {.serialize.}: ?StorageRequest
    state* {.serialize.}: string
    error* {.serialize.}: ?string

  RestAvailability* = object
    minimumPricePerBytePerSecond* {.serialize.}: TokensPerSecond
    maximumCollateralPerByte* {.serialize.}: Tokens
    maximumDuration* {.serialize.}: StorageDuration
    availableUntil* {.serialize.}: ?StorageTimestamp

  RestSalesSlot* = object
    state* {.serialize.}: string
    requestId* {.serialize.}: RequestId
    slotIndex* {.serialize.}: uint64
    request* {.serialize.}: ?StorageRequest

  RestContent* = object
    cid* {.serialize.}: Cid
    manifest* {.serialize.}: Manifest

  RestContentList* = object
    content* {.serialize.}: seq[RestContent]

  RestDatasetStatus* = object
    cid* {.serialize.}: Cid
    status* {.serialize.}: OverlayStatus
    expiry* {.serialize.}: SecondsSince1970
    hasBlocks* {.serialize.}: seq[bool]

  RestNode* = object
    nodeId* {.serialize.}: RestNodeId
    peerId* {.serialize.}: PeerId
    record* {.serialize.}: SignedPeerRecord
    address* {.serialize.}: Option[dn.Address]
    seen* {.serialize.}: bool

  RestRoutingTable* = object
    localNode* {.serialize.}: RestNode
    nodes* {.serialize.}: seq[RestNode]

  RestPeerRecord* = object
    peerId* {.serialize.}: PeerId
    seqNo* {.serialize.}: uint64
    addresses* {.serialize.}: seq[AddressInfo]

  RestNodeId* = object
    id*: NodeId

  RestRepoStore* = object
    totalBlocks* {.serialize.}: Natural
    quotaMaxBytes* {.serialize.}: NBytes
    quotaUsedBytes* {.serialize.}: NBytes
    quotaReservedBytes* {.serialize.}: NBytes

proc init*(_: type RestContentList, content: seq[RestContent]): RestContentList =
  RestContentList(content: content)

proc init*(_: type RestContent, cid: Cid, manifest: Manifest): RestContent =
  RestContent(cid: cid, manifest: manifest)

proc init*(
    _: type RestDatasetStatus,
    cid: Cid,
    overlay: OverlayMetadata,
    hasBlocks: seq[(Natural, bool)],
): RestDatasetStatus =
  RestDatasetStatus(
    cid: cid, status: overlay.status, expiry: overlay.expiry, hasBlocks: hasBlocks.mapIt(it[1])
  )

proc init*(_: type RestNode, node: dn.Node): RestNode =
  RestNode(
    nodeId: RestNodeId.init(node.id),
    peerId: node.record.data.peerId,
    record: node.record,
    address: node.address,
    seen: node.seen > 0.5,
  )

proc init*(_: type RestRoutingTable, routingTable: rt.RoutingTable): RestRoutingTable =
  var nodes: seq[RestNode] = @[]
  for bucket in routingTable.buckets:
    for node in bucket.nodes:
      nodes.add(RestNode.init(node))

  RestRoutingTable(localNode: RestNode.init(routingTable.localNode), nodes: nodes)

proc init*(_: type RestPeerRecord, peerRecord: PeerRecord): RestPeerRecord =
  RestPeerRecord(
    peerId: peerRecord.peerId, seqNo: peerRecord.seqNo, addresses: peerRecord.addresses
  )

proc init*(_: type RestNodeId, id: NodeId): RestNodeId =
  RestNodeId(id: id)

proc `%`*(obj: StorageRequest | Slot): JsonNode =
  let jsonObj = newJObject()
  for k, v in obj.fieldPairs:
    jsonObj[k] = %v
  jsonObj["id"] = %(obj.id)

  return jsonObj

proc `%`*(obj: RestNodeId): JsonNode =
  % $obj.id
