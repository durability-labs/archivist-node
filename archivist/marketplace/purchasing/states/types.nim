import ../statemachine

type PurchaseCancelled* = ref object of PurchaseState

type PurchaseErrored* = ref object of PurchaseState
  error*: ref CatchableError

type PurchaseFailed* = ref object of PurchaseState

type PurchaseFinished* = ref object of PurchaseState

type PurchasePending* = ref object of PurchaseState

type PurchaseStarted* = ref object of PurchaseState

type PurchaseSubmitted* = ref object of PurchaseState

type PurchaseUnknown* = ref object of PurchaseState
