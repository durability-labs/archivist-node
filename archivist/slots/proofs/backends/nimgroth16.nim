## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2025 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/sugar
import std/isolation
import std/atomics

import pkg/chronos
import pkg/chronos/threadsync
import pkg/taskpools
import pkg/questionable/results

from pkg/groth16 import Witness, Proof, generateProof, verifyProof, parseZKey
import pkg/groth16/files/r1cs
import pkg/groth16/zkey_types
import pkg/circom_witnessgen
import pkg/circom_witnessgen/load
from pkg/circom_witnessgen/witness import generateWitness
from pkg/circom_witnessgen/types import Inputs

import ../../types
import ../../../stores
import ../../../utils
import ../../../marketplace

import ./converters

export converters

logScope:
  topics = "archivist backend nimgroth16"

const DefaultCurve* = "bn128"

type
  NimGroth16Backend* = object
    curve: string # curve name
    slotDepth: int # max depth of the slot tree
    datasetDepth: int # max depth of dataset  tree
    blkDepth: int # depth of the block merkle tree (pow2 for now)
    cellElms: int # number of field elements per cell
    numSamples: int # number of samples per slot
    r1cs: R1CS # path to the r1cs file
    zkey: ZKey # path to the zkey file
    graph*: Graph # path to the graph file generated with circom-witnesscalc
    tp: Taskpool # taskpool for async operations

  NimGroth16BackendRef* = ref NimGroth16Backend

proc release*(self: NimGroth16BackendRef) =
  ## Release the ctx
  ##

  discard

proc normalizeInput[SomeHash](
    self: NimGroth16BackendRef, input: ProofInputs[SomeHash]
): Inputs =
  ## Map inputs to witnessgen inputs
  ##

  var normSlotProof = input.slotProof
  normSlotProof.setLen(self.datasetDepth)

  {
    "slotDepth": @[self.slotDepth.toF],
    "datasetDepth": @[self.datasetDepth.toF],
    "blkDepth": @[self.blkDepth.toF],
    "cellElms": @[self.cellElms.toF],
    "numSamples": @[self.numSamples.toF],
    "entropy": @[input.entropy],
    "dataSetRoot": @[input.datasetRoot],
    "slotIndex": @[input.slotIndex.toF],
    "slotRoot": @[input.slotRoot],
    "nCellsPerSlot": @[input.nCellsPerSlot.toF],
    "nSlotsPerDataSet": @[input.nSlotsPerDataSet.toF],
    "slotProof": normSlotProof,
    "cellData": input.samples.mapIt(it.cellData).concat,
    "merklePaths": input.samples.mapIt(
      block:
        var mekrlePaths = it.merklePaths
        mekrlePaths.setLen(self.slotDepth)
        mekrlePaths
    ).concat,
  }.toTable

proc generateWitnessValues(graph: Graph, inputs: Inputs): auto {.raises: [].} =
  ## Upstream circom_witnessgen uses unannotated proc-typed callbacks, which Nim
  ## conservatively infers as raising and not gcsafe. The closures only capture
  ## locals, so this is safe for the taskpool worker.
  {.cast(gcsafe).}:
    try:
      return generateWitness(graph, inputs)
    except Exception as exc:
      error "Exception generating witness", exc = exc.msg
      raiseAssert(exc.msg)

proc generateProofTask(
    ctx: SharedPtr[TaskCtx[NimGroth16Proof]],
    self: ptr NimGroth16Backend,
    inputs: ptr Inputs,
) {.gcsafe, raises: [].} =
  defer:
    if err =? ctx[].signal.fireSync().errorOption:
      warn "Failed to fire proof completion signal", error = err

  # Pre-initialized failure + unconditional write: if the worker dies
  # (witnessgen failures are raised as Defects, which no catch sees),
  # main still extracts a valid Result instead of an unwritten one.
  var r = ThreadSpawnRes[NimGroth16Proof].err("Failed to generate proof")
  defer:
    ctx[].result = isolate(move r)

  trace "Generating witness"
  let
    witnessValues = generateWitnessValues(self[].graph, inputs[])
    witness = Witness(
      curve: self[].curve,
      r: self[].r1cs.r,
      nvars: self[].r1cs.cfg.nWires,
      values: witnessValues,
    )

  trace "Generating nim groth16 proof"
  var proof = generateProof(self[].zkey, witness, self[].tp)
  trace "Proof generated, copying to main thread"
  r = ThreadSpawnRes[NimGroth16Proof].ok(proof)

proc prove*[SomeHash](
    self: NimGroth16BackendRef, input: ProofInputs[SomeHash]
): Future[?!NimGroth16Proof] {.async: (raises: [CancelledError]).} =
  ## Prove a statement using backend.
  ##

  var inputs = self.normalizeInput(input)
  await spawnJoin[NimGroth16Proof](
    proc(ctx: SharedPtr[TaskCtx[NimGroth16Proof]]) {.gcsafe, raises: [].} =
      self.tp.spawn generateProofTask(
        ctx, cast[ptr NimGroth16Backend](self), addr inputs
      )
  )

proc verify*(
    self: NimGroth16BackendRef, proof: NimGroth16Proof
): Future[?!bool] {.async: (raises: [CancelledError]).} =
  let
    vKey = self.zkey.extractVKey
    verified = ?verifyProof(vKey, proof).catch

  success verified

proc new*(
    _: type NimGroth16BackendRef,
    graphPath: string,
    r1csPath: string,
    zkeyPath: string,
    curve = DefaultCurve,
    slotDepth = DefaultMaxSlotDepth,
    datasetDepth = DefaultMaxDatasetDepth,
    blkDepth = DefaultBlockDepth,
    cellElms = DefaultCellElms,
    numSamples = DefaultSamplesNum,
    tp: Taskpool,
): ?!NimGroth16BackendRef =
  ## Create a new ctx
  ##

  let
    graph = ?loadGraph(graphPath).catch
    r1cs = ?parseR1CS(r1csPath).catch
    zkey = ?parseZKey(zkeyPath).catch

  success NimGroth16BackendRef(
    graph: graph,
    r1cs: r1cs,
    zkey: zkey,
    slotDepth: slotDepth,
    datasetDepth: datasetDepth,
    blkDepth: blkDepth,
    cellElms: cellElms,
    numSamples: numSamples,
    curve: curve,
    tp: tp,
  )
