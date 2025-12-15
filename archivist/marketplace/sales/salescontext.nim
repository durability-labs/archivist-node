import pkg/questionable
import pkg/libp2p/cid

import ../../clock
import ../abstractmarketplace
import ../availability/terms
import ../storageinterface
import ./slotqueue

type SalesContext* = ref object
  marketplace*: AbstractMarketplace
  clock*: Clock
  storage*: StorageInterface
  availabilityTerms*: ?AvailabilityTerms
  slotQueue*: SlotQueue
  when defined(archivist_system_testing_options):
    simulateProofFailures*: int
