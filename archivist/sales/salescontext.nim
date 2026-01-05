import pkg/questionable
import pkg/libp2p/cid

import ../marketplace/abstractmarketplace
import ../marketplace/availability/terms
import ../marketplace/storageinterface
import ../clock
import ./slotqueue

type SalesContext* = ref object
  marketplace*: AbstractMarketplace
  clock*: Clock
  storage*: StorageInterface
  availabilityTerms*: ?AvailabilityTerms
  slotQueue*: SlotQueue
  when defined(archivist_system_testing_options):
    simulateProofFailures*: int
