import ../../../conf
when defined(archivist_system_testing_options):
  import pkg/stint
  import pkg/ethers

  import ../../../logutils
  import ../../../utils/exceptions
  import ../../contracts/marketplacecontract
  import ../../contracts/requests
  import ../../abstractmarketplace
  import ../../storageinterface
  import ./proving

  logScope:
    topics = "marketplace sales simulated-proving"

  type SaleProvingSimulated* = ref object of SaleProving
    failEveryNProofs*: int
    proofCount: int

  proc onSubmitProofError(error: ref CatchableError, period: Period, slotId: SlotId) =
    error "Submitting invalid proof failed", period, slotId, msg = error.msgDetail

  method prove*(
      state: SaleProvingSimulated,
      slot: Slot,
      challenge: ProofChallenge,
      marketplace: AbstractMarketplace,
      storage: StorageInterface,
      currentPeriod: Period,
  ) {.async.} =
    try:
      trace "Processing proving in simulated mode"
      state.proofCount += 1
      if state.failEveryNProofs > 0 and state.proofCount mod state.failEveryNProofs == 0:
        state.proofCount = 0

        try:
          warn "Submitting INVALID proof", period = currentPeriod, slotId = slot.id
          await marketplace.submitProof(slot.id, Groth16Proof.default)
        except ProofInvalidError as e:
          discard # expected
        except CancelledError as error:
          raise error
        except CatchableError as e:
          onSubmitProofError(e, currentPeriod, slot.id)
      else:
        await procCall SaleProving(state).prove(
          slot, challenge, marketplace, storage, currentPeriod
        )
    except CancelledError as e:
      trace "Submitting INVALID proof cancelled", error = e.msgDetail
      raise e
    except CatchableError as e:
      error "Submitting INVALID proof failed", error = e.msgDetail
