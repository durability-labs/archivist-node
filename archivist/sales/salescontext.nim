import pkg/questionable
import pkg/questionable/results
import pkg/libp2p/cid

import ../marketplace/abstractmarketplace
import ../marketplace/availability/terms
import ../marketplace/storageinterface
import ../clock
import ../periods
import ./slotqueue

type
  SalesContext* = ref object
    marketplace*: AbstractMarketplace
    clock*: Clock
    storage*: StorageInterface
    # Sales-level callbacks. Closure will be overwritten each time a slot is
    # processed.
    onStore*: ?OnStore
    onClear*: ?OnClear
    onSale*: ?OnSale
    onProve*: ?OnProve
    onExpiryUpdate*: ?OnExpiryUpdate
    availabilityTerms*: ?AvailabilityTerms
    slotQueue*: SlotQueue
    when defined(archivist_system_testing_options):
      simulateProofFailures*: int

  OnStore* = proc(
    request: StorageRequest, expiry: SecondsSince1970, slot: uint64, isRepairing: bool
  ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).}
  OnProve* = proc(
    slot: Slot, challenge: ProofChallenge, period: Period
  ): Future[?!Groth16Proof] {.gcsafe, async: (raises: [CancelledError]).}
  OnExpiryUpdate* = proc(rootCid: Cid, expiry: SecondsSince1970): Future[?!void] {.
    gcsafe, async: (raises: [CancelledError])
  .}
  OnClear* = proc(request: StorageRequest, slotIndex: uint64) {.gcsafe, raises: [].}
  OnSale* = proc(request: StorageRequest, slotIndex: uint64) {.gcsafe, raises: [].}
