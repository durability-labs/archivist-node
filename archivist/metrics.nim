## Copyright (c) 2025 Archivist Authors
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.

{.push raises: [].}

import pkg/chronicles
import pkg/metrics

logScope:
  topics = "archivist metrics"

# Upload pipeline metrics
declarePublicHistogram(
  archivist_upload_batch_flush_duration_seconds,
  "Time to flush a single batch",
  buckets = [0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0],
)

declarePublicCounter(archivist_upload_blocks_total, "Total number of blocks uploaded")

declarePublicCounter(archivist_upload_batches_total, "Total number of batches flushed")

declarePublicCounter(archivist_upload_bytes_total, "Total bytes uploaded")

declarePublicHistogram(
  archivist_upload_tree_build_duration_seconds,
  "Time to build Merkle tree",
  buckets = [0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0],
)

declarePublicGauge(
  archivist_upload_active_batches, "Current number of in-flight batches"
)
