import pkg/questionable
import ../contracts/requests

type
  SalesSlot* = object
    requestId: RequestId
    request: ?StorageRequest
    slotIndex: uint64
    state: ?string

  SaleId* = SlotId

func init*(
    _: type SalesSlot,
    requestId: RequestId,
    slotIndex: uint64,
    request: ?StorageRequest,
    state: ?string,
): SalesSlot =
  SalesSlot(requestId: requestId, request: request, slotIndex: slotIndex, state: state)

func id*(sale: SalesSlot): SaleId =
  slotId(sale.requestId, sale.slotIndex)

func requestId*(sale: SalesSlot): RequestId =
  sale.requestId

func slotIndex*(sale: SalesSlot): uint64 =
  sale.slotIndex

func request*(sale: SalesSlot): ?StorageRequest =
  sale.request

func state*(sale: SalesSlot): ?string =
  sale.state
