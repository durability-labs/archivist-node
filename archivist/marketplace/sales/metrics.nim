import pkg/metrics
import ../periods

declareGauge(archivist_proofs_per_period, "archivist proofs per period")

type SalesMetrics* = object
  currentPeriod: Period
  proofsPerPeriod: int64

proc increaseNumberOfProofs*(metrics: var SalesMetrics, period: Period) =
  if period > metrics.currentPeriod:
    if metrics.currentPeriod > 0:
      archivist_proofs_per_period.set(metrics.proofsPerPeriod)
    metrics.currentPeriod = period
    metrics.proofsPerPeriod = 0
  inc metrics.proofsPerPeriod
