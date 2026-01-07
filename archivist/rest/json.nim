import std/tables
from std/json import
  parseJson, JsonParsingError, hasKey, `[]`, `[]=`, kind, JString, JObject, getStr, pairs,
  newJObject, newJString, newJInt, newJBool, newJArray, add

import pkg/questionable
import pkg/stew/byteutils
import pkg/libp2p
import pkg/archivistdht/discv5/node as dn
import pkg/archivistdht/discv5/routing_table as rt
import ../marketplace
import ../utils/json
import ../manifest
import ../units
import ../clock

export json

type
  StorageRequestParams* = object
    duration* {.serialize.}: uint64
    proofProbability* {.serialize.}: UInt256
    pricePerBytePerSecond* {.serialize.}: UInt256
    collateralPerByte* {.serialize.}: UInt256
    expiry* {.serialize.}: uint64
    nodes* {.serialize.}: ?uint
    tolerance* {.serialize.}: ?uint

  RestPurchase* = object
    requestId* {.serialize.}: RequestId
    request* {.serialize.}: ?StorageRequest
    state* {.serialize.}: string
    error* {.serialize.}: ?string

  RestAvailability* = object
    minimumPricePerBytePerSecond* {.serialize.}: UInt256
    maximumCollateralPerByte* {.serialize.}: UInt256
    maximumDuration* {.serialize.}: uint64
    availableUntil* {.serialize.}: ?SecondsSince1970

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

  RestDirectoryRequest* = object
    ## Request body for POST /api/archivist/v1/directory
    name* {.serialize.}: string
    entries* {.serialize.}: OrderedTable[string, string]
      # path -> CID string mapping

  RestDirectoryResponse* = object
    ## Response body for directory creation
    cid* {.serialize.}: string
    totalSize* {.serialize.}: uint64
    fileCount* {.serialize.}: int
    protected* {.serialize.}: bool

  RestDirectoryListing* = object
    ## Response body for directory browsing (GET /api/archivist/v1/data/{cid})
    cid* {.serialize.}: string
    name* {.serialize.}: string
    totalSize* {.serialize.}: uint64
    fileCount* {.serialize.}: int
    protected* {.serialize.}: bool
    entries* {.serialize.}: OrderedTable[string, string]
      # path -> CID string mapping

proc init*(_: type RestContentList, content: seq[RestContent]): RestContentList =
  RestContentList(content: content)

proc init*(_: type RestContent, cid: Cid, manifest: Manifest): RestContent =
  RestContent(cid: cid, manifest: manifest)

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

proc `%`*(obj: Manifest): JsonNode =
  ## Custom JSON serializer for Manifest that handles OrderedTable[string, Cid]
  let jsonObj = newJObject()

  # Base fields
  jsonObj["treeCid"] = newJString($obj.treeCid)
  jsonObj["datasetSize"] = newJInt(obj.datasetSize.int64)
  jsonObj["blockSize"] = newJInt(obj.blockSize.int64)
  jsonObj["codec"] = newJString($obj.codec)
  jsonObj["hcodec"] = newJString($obj.hcodec)
  jsonObj["version"] = newJString($obj.version)

  # Optional fields
  if obj.path.isSome:
    jsonObj["path"] = newJString(obj.path.get)
  if obj.mimetype.isSome:
    jsonObj["mimetype"] = newJString(obj.mimetype.get)

  # Directory case
  jsonObj["isDirectory"] = newJBool(obj.isDirectory)
  if obj.isDirectory:
    jsonObj["name"] = newJString(obj.name)
    let entriesObj = newJObject()
    for path, cid in obj.entries.pairs:
      entriesObj[path] = newJString($cid)
    jsonObj["entries"] = entriesObj

  # Protected case
  jsonObj["protected"] = newJBool(obj.protected)
  if obj.protected:
    jsonObj["ecK"] = newJInt(obj.ecK.BiggestInt)
    jsonObj["ecM"] = newJInt(obj.ecM.BiggestInt)
    jsonObj["originalTreeCid"] = newJString($obj.originalTreeCid)
    jsonObj["originalDatasetSize"] = newJInt(obj.originalDatasetSize.int64)
    jsonObj["protectedStrategy"] = newJString($obj.protectedStrategy)

    # Verifiable case
    jsonObj["verifiable"] = newJBool(obj.verifiable)
    if obj.verifiable:
      jsonObj["verifyRoot"] = newJString($obj.verifyRoot)
      var slotRootsArr = newJArray()
      for root in obj.slotRoots:
        slotRootsArr.add(newJString($root))
      jsonObj["slotRoots"] = slotRootsArr
      jsonObj["cellSize"] = newJInt(obj.cellSize.int64)
      jsonObj["verifiableStrategy"] = newJString($obj.verifiableStrategy)

  return jsonObj

proc init*(
    _: type RestDirectoryResponse,
    cid: Cid,
    totalSize: NBytes,
    fileCount: int,
    protected: bool,
): RestDirectoryResponse =
  RestDirectoryResponse(
    cid: $cid,
    totalSize: totalSize.uint64,
    fileCount: fileCount,
    protected: protected,
  )

proc init*(
    _: type RestDirectoryListing,
    cid: Cid,
    manifest: Manifest,
): RestDirectoryListing =
  var entries: OrderedTable[string, string]
  if manifest.isDirectory:
    for path, entryCid in manifest.entries.pairs:
      entries[path] = $entryCid

  RestDirectoryListing(
    cid: $cid,
    name: if manifest.isDirectory: manifest.name else: "",
    totalSize: manifest.datasetSize.uint64,
    fileCount: if manifest.isDirectory: manifest.entries.len else: 0,
    protected: manifest.protected,
    entries: entries,
  )

proc `%`*(obj: RestDirectoryResponse): JsonNode =
  let jsonObj = newJObject()
  jsonObj["cid"] = newJString(obj.cid)
  jsonObj["totalSize"] = newJInt(obj.totalSize.BiggestInt)
  jsonObj["fileCount"] = newJInt(obj.fileCount.BiggestInt)
  jsonObj["protected"] = newJBool(obj.protected)

  return jsonObj

proc `%`*(obj: RestDirectoryListing): JsonNode =
  let entriesObj = newJObject()
  for path, cid in obj.entries.pairs:
    entriesObj[path] = newJString(cid)

  let jsonObj = newJObject()
  jsonObj["cid"] = newJString(obj.cid)
  jsonObj["name"] = newJString(obj.name)
  jsonObj["totalSize"] = newJInt(obj.totalSize.BiggestInt)
  jsonObj["fileCount"] = newJInt(obj.fileCount.BiggestInt)
  jsonObj["protected"] = newJBool(obj.protected)
  jsonObj["entries"] = entriesObj

  return jsonObj

proc fromJson*(
    _: type RestDirectoryRequest, bytes: seq[byte]
): ?!RestDirectoryRequest =
  ## Parse a RestDirectoryRequest from JSON bytes
  try:
    let json = parseJson(string.fromBytes(bytes))

    if not json.hasKey("name"):
      return failure("Missing required field: name")

    if not json.hasKey("entries"):
      return failure("Missing required field: entries")

    let nameNode = json["name"]
    if nameNode.kind != JString:
      return failure("Field 'name' must be a string")

    let entriesNode = json["entries"]
    if entriesNode.kind != JObject:
      return failure("Field 'entries' must be an object")

    var entries: OrderedTable[string, string]
    for path, cidNode in entriesNode.pairs:
      if cidNode.kind != JString:
        return failure("Entry value for path '" & path & "' must be a string CID")
      entries[path] = cidNode.getStr()

    success RestDirectoryRequest(name: nameNode.getStr(), entries: entries)
  except JsonParsingError as e:
    failure("Invalid JSON: " & e.msg)
  except CatchableError as e:
    failure("Failed to parse directory request: " & e.msg)
