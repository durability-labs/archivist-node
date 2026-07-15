import std/math
import ../../../asynctest
import ../../../../archivist/blockexchange/peers/peerscore

suite "PeerScore":
  test "computeScore returns ColdStartScore for cold-start peers":
    var s = PeerScore(lastUpdated: Moment.now())
    s.totalDeliveries = 0
    check s.computeScore(inflightCount = 0) == ColdStartScore

  test "computeScore returns ColdStartScore when totalDeliveries < MinSamplesForScore":
    var s = PeerScore(lastUpdated: Moment.now())
    s.totalDeliveries = MinSamplesForScore - 1
    check s.computeScore(inflightCount = 0) == ColdStartScore

  test "computeScore applies load penalty for active peers":
    let s = PeerScore(
      lastUpdated: Moment.now(),
      totalDeliveries: 10,
      totalFailures: 0,
      successRate: 1.0,
      throughputBps: ThroughputCapBps,
      latencyMs: 0.0,
    )
    # No in-flight: full score = 0.3*1 + 0.5*1 + 0.2*1 = 1.0
    let baseScore = s.computeScore(inflightCount = 0)
    check baseScore > 0.95
    # With in-flight: loadPenalty = 1/(1+5*0.1) = 0.667
    let loadedScore = s.computeScore(inflightCount = 5)
    check loadedScore < baseScore
    check loadedScore > baseScore * 0.6

  test "applyDecay returns rawScore when inflightCount > 0":
    let now = Moment.now()
    let lastUpdated = now - 10.minutes
    let decayed = applyDecay(0.5, lastUpdated, inflightCount = 1, now)
    check decayed == 0.5

  test "applyDecay returns rawScore within grace period":
    let now = Moment.now()
    let lastUpdated = now - DecayGracePeriod + 1.seconds
    let decayed = applyDecay(0.5, lastUpdated, inflightCount = 0, now)
    check decayed == 0.5

  test "applyDecay applies exponential decay after grace period":
    let now = Moment.now()
    let lastUpdated = now - (DecayGracePeriod + DecayTau)
    let decayed = applyDecay(0.5, lastUpdated, inflightCount = 0, now)
    # After grace + one tau: 0.5 * exp(-1) ≈ 0.184.
    # Crucial: decay must start at grace boundary, not during grace.
    check decayed < 0.5
    check decayed > ColdStartScore
    check abs(decayed - 0.5 * exp(-1.0)) < 0.01

  test "applyDecay floors at ColdStartScore":
    let now = Moment.now()
    let lastUpdated = now - 24.hours
    let decayed = applyDecay(0.1, lastUpdated, inflightCount = 0, now)
    check decayed == ColdStartScore

  test "checkCircuitBreaker opens after MaxConsecutiveFailures":
    var s = PeerScore(lastUpdated: Moment.now())
    s.consecutiveFailures = MaxConsecutiveFailures
    s.checkCircuitBreaker()
    check s.circuitOpen
    check s.circuitOpenUntil > Moment.now()

  test "checkCircuitBreaker does not open at MaxConsecutiveFailures - 1":
    var s = PeerScore(lastUpdated: Moment.now())
    s.consecutiveFailures = MaxConsecutiveFailures - 1
    s.checkCircuitBreaker()
    check not s.circuitOpen

  test "recordFailure with isValidation=true increments by ValidationFailureWeight":
    var s = PeerScore(lastUpdated: Moment.now())
    s.recordFailure(isValidation = true)
    check s.consecutiveFailures == ValidationFailureWeight
    check s.totalFailures == ValidationFailureWeight

  test "recordFailure with isValidation=false increments by 1":
    var s = PeerScore(lastUpdated: Moment.now())
    s.recordFailure(isValidation = false)
    check s.consecutiveFailures == 1
    check s.totalFailures == 1

  test "recordFailure decays throughputBps toward 0":
    var s = PeerScore(lastUpdated: Moment.now())
    s.throughputBps = 50_000_000.0
    s.recordFailure()
    check s.throughputBps < 50_000_000.0

  test "recordFailure decays latencyMs toward LatencyCapMs":
    var s = PeerScore(lastUpdated: Moment.now())
    s.latencyMs = 100.0
    s.recordFailure()
    check s.latencyMs > 100.0
    check s.latencyMs <= LatencyCapMs

  test "recordDelivery resets consecutiveFailures to 0":
    var s = PeerScore(lastUpdated: Moment.now())
    s.consecutiveFailures = 3
    s.recordDelivery(1024, 50.0)
    check s.consecutiveFailures == 0

  test "recordDelivery updates totalDeliveries and totalBytes":
    var s = PeerScore(lastUpdated: Moment.now())
    s.recordDelivery(2048, 100.0)
    check s.totalDeliveries == 1
    check s.totalBytes == 2048
    s.recordDelivery(1024, 50.0)
    check s.totalDeliveries == 2
    check s.totalBytes == 3072

  test "maybeResetCircuit clears circuit when cooldown elapsed":
    var s = PeerScore(lastUpdated: Moment.now())
    s.circuitOpen = true
    s.circuitOpenUntil = Moment.now() - 1.seconds
    s.consecutiveFailures = 10
    let before = Moment.now()
    s.maybeResetCircuit()
    check not s.circuitOpen
    check s.consecutiveFailures == 0
    check s.lastUpdated >= before

  test "maybeResetCircuit preserves circuit when cooldown active":
    var s = PeerScore(lastUpdated: Moment.now())
    s.circuitOpen = true
    s.circuitOpenUntil = Moment.now() + 60.seconds
    s.consecutiveFailures = 10
    s.maybeResetCircuit()
    check s.circuitOpen
    check s.consecutiveFailures == 10

  test "sendBatchFailure increments consecutiveFailures by exactly 1":
    var s = PeerScore(lastUpdated: Moment.now())
    s.consecutiveFailures = 2
    s.sendBatchFailure()
    check s.consecutiveFailures == 3
    check s.totalFailures == 1

  test "recordDelivery does not bypass circuit breaker cooldown":
    var s = PeerScore(lastUpdated: Moment.now())
    s.circuitOpen = true
    s.circuitOpenUntil = Moment.now() + 60.seconds
    s.consecutiveFailures = MaxConsecutiveFailures
    s.recordDelivery(1024, 50.0)
    check s.circuitOpen
    check s.consecutiveFailures == 0
    check s.totalDeliveries == 1
