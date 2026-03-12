import ../statemachine

type
  SaleUnknown* = ref object of SaleState
  SaleErrored* = ref object of SaleState
    error*: ref CatchableError
    reprocessSlot*: bool
