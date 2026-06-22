## Copyright (c) 2025 Archivist Authors
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/math

import pkg/chronos

const
  # Score components and weights
  SuccessWeight* = 0.3
  ThroughputWeight* = 0.5
  LatencyWeight* = 0.2

  # Normalization caps
  ThroughputCapBps* = 100_000_000.0 # 100 MB/s ceiling
  LatencyCapMs* = 10_000.0 # 10s ceiling

  # EWMA smoothing
  EwmaAlpha* = 0.1

  # Load penalty
  InflightPenaltyFactor* = 0.1

  # Cold start: a peer with fewer than this many deliveries scores ColdStartScore
  # and skips the load penalty entirely.
  MinSamplesForScore* = 3
  ColdStartScore* = 0.1

  # Circuit breaker
  MaxConsecutiveFailures* = 5
  ValidationFailureWeight* = 2
  CircuitCooldown* = 60.seconds

  DefaultRequestTimeout* = 30.seconds
  DecayGracePeriod* = 2 * DefaultRequestTimeout
  DecayTau* = 2.minutes

type PeerScore* = object
  successRate*: float
  throughputBps*: float
  latencyMs*: float
  consecutiveFailures*: int
  totalDeliveries*: int
  totalFailures*: int
  totalBytes*: int
  circuitOpen*: bool
  circuitOpenUntil*: Moment
  score*: float
  lastUpdated*: Moment

template ewmaUpdate(metric, sample; alpha = EwmaAlpha) =
  metric = alpha * sample + (1.0 - alpha) * metric

proc loadPenalty(inflightCount: int): float =
  1.0 / (1.0 + float(inflightCount) * InflightPenaltyFactor)

proc computeScore*(self: var PeerScore, inflightCount: int) =
  if self.totalDeliveries < MinSamplesForScore:
    self.score = ColdStartScore
    return

  let
    successNorm = clamp(self.successRate, 0.0, 1.0)
    throughputNorm = min(self.throughputBps / ThroughputCapBps, 1.0)
    latencyNorm = max(0.0, 1.0 - self.latencyMs / LatencyCapMs)
    rawScore =
      SuccessWeight * successNorm + ThroughputWeight * throughputNorm +
      LatencyWeight * latencyNorm

  self.score = rawScore * loadPenalty(inflightCount)

proc applyDecay*(
    rawScore: float, lastUpdated: Moment, inflightCount: int, now: Moment
): float =
  if inflightCount > 0:
    return rawScore

  let elapsed = now - lastUpdated
  if elapsed <= DecayGracePeriod:
    return rawScore

  # Decay only kicks in AFTER the grace period — score is held flat during
  # grace, then decays from 1.0 downward.
  let
    pastGrace = elapsed - DecayGracePeriod
    pastGraceNs = float(pastGrace.nanoseconds)
    tauNs = float(DecayTau.nanoseconds)
    decayFactor = exp(-pastGraceNs / tauNs)

  max(rawScore * decayFactor, ColdStartScore)

proc checkCircuitBreaker*(self: var PeerScore) =
  if self.consecutiveFailures >= MaxConsecutiveFailures and not self.circuitOpen:
    self.circuitOpen = true
    self.circuitOpenUntil = Moment.now() + CircuitCooldown

proc maybeResetCircuit*(self: var PeerScore) =
  if not self.circuitOpen:
    return

  if Moment.now() < self.circuitOpenUntil:
    return

  # Reset to cold-start values; reset decay clock.
  self = PeerScore(lastUpdated: Moment.now())

proc recordDelivery*(self: var PeerScore, bytes: int, latencyMs: float) =
  self.totalDeliveries += 1
  self.totalBytes += bytes
  self.consecutiveFailures = 0
  # Do NOT clear circuitOpen here — a late in-flight delivery must not
  # bypass CircuitCooldown. maybeResetCircuit (called by scoredPeer)
  # is the sole authority for closing the circuit.
  # Update success rate via EWMA on the deliveries/failures ratio.
  if self.totalDeliveries + self.totalFailures > 0:
    let ratio =
      float(self.totalDeliveries) / float(self.totalDeliveries + self.totalFailures)
    ewmaUpdate(self.successRate, ratio)

  # Latency EWMA
  ewmaUpdate(self.latencyMs, latencyMs)

  # Throughput EWMA. Guard against zero or near-zero latency.
  let seconds = max(latencyMs / 1000.0, 0.001)
  ewmaUpdate(self.throughputBps, float(bytes) / seconds)
  self.lastUpdated = Moment.now()

proc recordFailure*(self: var PeerScore, isValidation: bool = false) =
  let weight = if isValidation: ValidationFailureWeight else: 1
  self.consecutiveFailures += weight
  self.totalFailures += weight
  # EWMA updates are applied `weight` times so a validation failure
  # (weight=2) has proportionally more impact on the smoothed metrics
  # than a normal failure (weight=1), not just on the counters.
  for _ in 0 ..< weight:
    # A failure pulls successRate toward 0.
    ewmaUpdate(self.successRate, 0.0)
    # Decay throughput toward 0 (a failing peer isn't delivering bytes).
    ewmaUpdate(self.throughputBps, 0.0)
    # Decay latency toward LatencyCapMs (not 0 - failing peers aren't fast).
    ewmaUpdate(self.latencyMs, LatencyCapMs)

  self.checkCircuitBreaker()
  self.lastUpdated = Moment.now()

proc sendBatchFailure*(self: var PeerScore) =
  self.consecutiveFailures += 1
  self.totalFailures += 1
  ewmaUpdate(self.successRate, 0.0)
  ewmaUpdate(self.throughputBps, 0.0)
  ewmaUpdate(self.latencyMs, LatencyCapMs)
  self.checkCircuitBreaker()
  self.lastUpdated = Moment.now()
