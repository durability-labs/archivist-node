{.push raises: [].}

import pkg/metrics
export metrics

# ── Throughput counters ──
declarePublicCounter(
  archivist_block_exchange_blocks_sent, "archivist blockexchange blocks sent"
)
declarePublicCounter(
  archivist_block_exchange_bytes_sent, "archivist blockexchange bytes sent"
)
declarePublicCounter(
  archivist_block_exchange_blocks_received, "archivist blockexchange blocks received"
)
declarePublicCounter(
  archivist_block_exchange_bytes_received, "archivist blockexchange bytes received"
)

# ── Want-list counters ──
declarePublicCounter(
  archivist_block_exchange_want_have_lists_received,
  "archivist blockexchange wantHave lists received",
)
declarePublicCounter(
  archivist_block_exchange_want_have_lists_sent,
  "archivist blockexchange wantHave lists sent",
)
declarePublicCounter(
  archivist_block_exchange_want_block_lists_sent,
  "archivist blockexchange wantBlock lists sent",
)
declarePublicCounter(
  archivist_block_exchange_want_block_lists_received,
  "archivist blockexchange wantBlock lists received",
)

# ── Want-entry counters (entry-level granularity) ──
declarePublicCounter(
  archivist_block_exchange_want_have_entries_sent,
  "archivist blockexchange wantHave entries sent",
)
declarePublicCounter(
  archivist_block_exchange_want_have_entries_received,
  "archivist blockexchange wantHave entries received",
)
declarePublicCounter(
  archivist_block_exchange_want_block_entries_sent,
  "archivist blockexchange wantBlock entries sent",
)
declarePublicCounter(
  archivist_block_exchange_want_block_entries_received,
  "archivist blockexchange wantBlock entries received",
)

# ── Discovery / peer counters ──
# NOTE: variable name is `discovery_requests` (NOT `_total`) — library auto-appends `_total`
declarePublicCounter(
  archivist_block_exchange_discovery_requests,
  "Total number of peer discovery requests sent",
)
declarePublicCounter(
  archivist_block_exchange_peer_timeouts, "Total number of peer activity timeouts"
)
declarePublicCounter(
  archivist_block_exchange_requests_failed,
  "Total number of block requests that failed after exhausting retries",
)

# ── Spurious / retry counters ──
declarePublicCounter(
  archivist_block_exchange_spurious_blocks_received,
  "archivist blockexchange unrequested/duplicate blocks received",
)

# ── Handle lifecycle counters ──
declarePublicCounter(
  archivist_block_exchange_handles_created, "Total number of block handles created"
)
declarePublicCounter(
  archivist_block_exchange_handles_resolved,
  "Total number of block handles resolved successfully",
)
declarePublicCounter(
  archivist_block_exchange_handles_failed, "Total number of block handles that failed"
)
declarePublicCounter(
  archivist_block_exchange_handles_missing_on_release,
  "Total number of release attempts on already-resolved handles",
)

# ── Request outcome counters ──
declarePublicCounter(
  archivist_block_exchange_requests_succeeded,
  "Total number of block requests that succeeded",
)
declarePublicCounter(
  archivist_block_exchange_requests_retried,
  "Total number of block request retries",
  labels = ["reason", "attempt"],
)
declarePublicCounter(
  archivist_block_exchange_requests_abandoned,
  "Total number of block requests abandoned",
)

# ── State gauges ──
declarePublicGauge(
  archivist_block_exchange_pending_block_requests,
  "archivist blockexchange pending block requests",
)

# ── Inflight gauges (moved from advertiser.nim and discovery.nim) ──
declarePublicGauge(archivist_inflight_advertise, "inflight advertise requests")
declarePublicGauge(archivist_inflight_discovery, "inflight discovery requests")

# ── Sender capacity gauges (service-side saturation) ──
# task_queue_depth / inflight_* answer "are we queueing or saturated?"
declarePublicGauge(
  archivist_block_exchange_task_queue_depth,
  "Peers waiting on the block-serve task queue",
)
declarePublicGauge(
  archivist_block_exchange_active_serve_tasks,
  "taskHandler invocations currently running",
)
declarePublicGauge(
  archivist_block_exchange_inflight_sends,
  "Network messages currently holding the inflight send semaphore",
)
declarePublicGauge(
  archivist_block_exchange_inflight_send_slots_free,
  "Free slots on the inflight send semaphore",
)
declarePublicGauge(
  archivist_block_exchange_wanted_blocks,
  "Total blocks peers currently want from this node (sum wantedBlocks)",
)
declarePublicCounter(
  archivist_block_exchange_task_queue_full,
  "scheduleTask dropped because task queue was full",
)

# ── Duration histograms ──
# Buckets span ~1ms-120s so p95 does not clip at the default 10s top bucket.
const BlockExcDurationBuckets = [
  0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0, 60.0,
  120.0,
]

declarePublicHistogram(
  archivist_block_exchange_retrieval_duration_seconds,
  "archivist blockexchange block retrieval duration in seconds",
  buckets = BlockExcDurationBuckets,
)
declarePublicHistogram(
  archivist_block_exchange_request_outcome_duration_seconds,
  "Block request duration by outcome type",
  labels = ["outcome"],
  buckets = BlockExcDurationBuckets,
)

# Split serve-path latency: queue wait vs store read vs network send.
# Queue wait high + service low => capacity problem. Service high => store/net.
declarePublicHistogram(
  archivist_block_exchange_task_queue_wait_seconds,
  "Time from scheduleTask to taskHandler start (queue wait)",
  buckets = BlockExcDurationBuckets,
)
declarePublicHistogram(
  archivist_block_exchange_task_store_read_seconds,
  "Time reading wanted blocks from local store in taskHandler",
  buckets = BlockExcDurationBuckets,
)
declarePublicHistogram(
  archivist_block_exchange_task_send_seconds,
  "Time sending all delivery batches for one taskHandler run",
  buckets = BlockExcDurationBuckets,
)
declarePublicHistogram(
  archivist_block_exchange_network_inflight_wait_seconds,
  "Time waiting to acquire the inflight send semaphore",
  labels = ["kind"],
  buckets = BlockExcDurationBuckets,
)
declarePublicHistogram(
  archivist_block_exchange_network_send_seconds,
  "End-to-end network send time (inflight wait + writeLp)",
  labels = ["kind"],
  buckets = BlockExcDurationBuckets,
)

# Receiver-side: time the serial readLoop handler (validate + store + resolve).
# High handler time blocks the next readLp, causing TCP backpressure on sender.
declarePublicHistogram(
  archivist_block_exchange_recv_handler_seconds,
  "Time inside blocksDeliveryHandler (validate + store + resolve) per message",
  buckets = BlockExcDurationBuckets,
)
declarePublicHistogram(
  archivist_block_exchange_recv_decode_seconds,
  "Time to protobufDecode incoming message in readLoop",
  buckets = BlockExcDurationBuckets,
)
# Sender-side: split network_send into encode (sync CPU) vs writeLp (TCP I/O).
declarePublicHistogram(
  archivist_block_exchange_network_encode_seconds,
  "Time to protobufEncode outgoing message (sync, blocks event loop)",
  labels = ["kind"],
  buckets = BlockExcDurationBuckets,
)
declarePublicHistogram(
  archivist_block_exchange_network_write_seconds,
  "Time in conn.writeLp (TCP write) after encode",
  labels = ["kind"],
  buckets = BlockExcDurationBuckets,
)
# Bytes per writeLp call — post-protobufEncode buffer size.
# Used to compute per-write throughput and verify the 64MB-per-batch assumption.
# Top bucket 128MiB covers 128x512KiB blocks + protobuf framing without
# clamping p50/p95 into +Inf.
declarePublicHistogram(
  archivist_block_exchange_network_write_bytes,
  "Bytes written per conn.writeLp call (post-protobufEncode buffer)",
  labels = ["kind"],
  buckets = [
    0.0, 1024.0, 16384.0, 65536.0, 262144.0, 1048576.0, 4194304.0, 16777216.0,
    67108864.0, 134217728.0,
  ],
)
