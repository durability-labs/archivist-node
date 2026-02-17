#!/bin/bash
# e2e-test.sh - Quick E2E test launcher
#
# Run from the archivist-node-e2e-testing root:
#   ./e2e/e2e-test.sh 5 basic
#
# Debug mode (preserve data):
#   DEBUG=1 ./e2e/e2e-test.sh 5 basic

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_BASE="$(dirname "$SCRIPT_DIR")"

export PATH="/opt/homebrew/bin:$PATH"

cd "$E2E_BASE"

NUM_NODES=${1:-5}
TEST_TYPE=${2:-basic}
BASE_API_PORT=${3:-9080} # Use 9080+ to avoid conflicts with other sessions
BASE_METRICS_PORT=${4:-10008}
BASE_DISC_PORT=${5:-19080}
MARKETPLACE_ADDRESS=${MARKETPLACE_ADDRESS:-"0x4A679253410272dd5232B3Ff7cF5dbB88f295319"}

echo "========================================"
echo "Archivist E2E Test Runner"
echo "========================================"
echo "Nodes: $NUM_NODES"
echo "Test:  $TEST_TYPE"
echo "Base:  $E2E_BASE"
echo "========================================"

# ============================================================
# CLEANUP: Stop existing processes and clean data dirs
# (Skip if debugging a failure - set DEBUG=1)
# ============================================================
if [ -z "$DEBUG" ]; then
  echo ""
  echo "[1/5] Cleaning up previous run..."
  pkill -f 'archivist.*e2e' 2>/dev/null || true
  pkill -f 'hardhat' 2>/dev/null || true
  sleep 3
  rm -rf /tmp/archivist-e2e/
  echo "      Cleanup complete"
else
  echo ""
  echo "[1/5] DEBUG mode: preserving previous data for investigation"
fi

# ============================================================
# PREREQ: Ensure built
# ============================================================
echo ""
echo "[2/5] Checking build..."
if [ ! -f "$E2E_BASE/build/archivist" ]; then
  echo "      Building archivist..."
  nimble build
else
  echo "      Already built"
fi

# ============================================================
# CIRCUITS: Copy circuit files for prover
# ============================================================
echo ""
echo "[2.5/5] Setting up circuits..."
CIRCUITS_DIR="/tmp/archivist-e2e/circuits"
SRC_CIRCUITS="$E2E_BASE/tests/circuits/fixtures"

mkdir -p "$CIRCUITS_DIR"
cp -f "$SRC_CIRCUITS"/*.wasm "$SRC_CIRCUITS"/*.zkey "$SRC_CIRCUITS"/*.r1cs "$SRC_CIRCUITS"/*.bin "$CIRCUITS_DIR/" 2>/dev/null || true

snarkjs zkey export verificationkey "$CIRCUITS_DIR/proof_main.zkey" "$CIRCUITS_DIR/proof_main_verification_key.json" 2>/dev/null || true
echo "      Circuits ready"

# ============================================================
# HARDHAT: Start blockchain
# ============================================================
echo ""
echo "[3/5] Starting Hardhat..."

# Check if Hardhat is already running
if nc -z localhost 8545 2>/dev/null; then
  echo "      Hardhat already running on port 8545, using existing instance"
else
  # npm run start: starts hardhat node, mines 256 blocks, deploys contracts
  (cd "$E2E_BASE/vendor/archivist-contracts" && npm run start) &
  HARDHAT_PID=$!
  echo "      Hardhat PID: $HARDHAT_PID"

  # Wait for Hardhat + deployment to be ready
  echo "      Waiting for Hardhat..."
  for i in $(seq 1 60); do
    if curl -s -X POST http://localhost:8545 \
      -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
      >/dev/null 2>&1; then
      echo "      Hardhat ready!"
      break
    fi
    if [ "$i" -eq 60 ]; then
      echo "ERROR: Hardhat failed to start"
      kill $HARDHAT_PID 2>/dev/null || true
      exit 1
    fi
    sleep 1
  done

  # Wait for contract deployment to complete (npm run start handles deploy)
  echo "      Waiting for contract deployment..."
  sleep 15
  echo "      Contracts deployed"
fi

# ============================================================
# NODES: Start cluster
# ============================================================
echo ""
echo "[4/5] Starting $NUM_NODES nodes..."

# Create directories
for n in $(seq 1 $NUM_NODES); do
  mkdir -p /tmp/archivist-e2e/node${n}/{data,logs}
done

# Start bootstrap node (Node 1)
echo "      Starting Node 1 (bootstrap)..."
PORT=$BASE_API_PORT
METRICS=$BASE_METRICS_PORT
DISC=$BASE_DISC_PORT
"$E2E_BASE/build/archivist_e2e" \
  --data-dir=/tmp/archivist-e2e/node1/data \
  --circuit-dir="$CIRCUITS_DIR" \
  --api-port=$PORT --disc-port=$DISC --metrics --metrics-port=$METRICS \
  --persistence --eth-provider=ws://localhost:8545 \
  --eth-private-key="$E2E_BASE/tests/testbed/network/hardhat/keys/account0.key" \
  --marketplace-address="$MARKETPLACE_ADDRESS" \
  --validator --prover \
  --log-level="INFO;TRACE:archivist,blockexchange,marketplace" \
  >/tmp/archivist-e2e/node1/logs/archivist.log 2>&1 &
NODE1_PID=$!
echo "      Node 1 PID: $NODE1_PID"

# Wait for Node 1 to be ready
echo "      Waiting for Node 1..."
for i in {1..30}; do
  if curl -s http://localhost:$PORT/api/archivist/v1/debug/info >/dev/null 2>&1; then
    echo "      Node 1 ready!"
    break
  fi
  sleep 1
done

# Get SPR from bootstrap node
SPR=$(curl -s http://localhost:$PORT/api/archivist/v1/spr | jq -r '.spr')
echo "      Got bootstrap SPR"

# Start remaining nodes
for i in $(seq 2 $NUM_NODES); do
  PORT=$(($BASE_API_PORT + $i - 1))
  METRICS=$(($BASE_METRICS_PORT + $i - 1))
  DISC=$(($BASE_DISC_PORT + $i - 1))
  KEY=$((i - 1))

  echo "      Starting Node $i (port $PORT)..."
  "$E2E_BASE/build/archivist_e2e" \
    --data-dir=/tmp/archivist-e2e/node${i}/data \
    --circuit-dir="$CIRCUITS_DIR" \
    --api-port=$PORT --disc-port=$DISC --metrics --metrics-port=$METRICS \
    --bootstrap-node="$SPR" \
    --persistence --eth-provider=ws://localhost:8545 \
    --eth-private-key="$E2E_BASE/tests/testbed/network/hardhat/keys/account${KEY}.key" \
    --marketplace-address="$MARKETPLACE_ADDRESS" \
    --validator --prover \
    --log-level="INFO;TRACE:archivist,blockexchange,marketplace" \
    >/tmp/archivist-e2e/node${i}/logs/archivist.log 2>&1 &
done

# Wait for all nodes to be ready
echo "      Waiting for all nodes..."
sleep 15

# Verify all nodes are up
for i in $(seq 1 $NUM_NODES); do
  PORT=$(($BASE_API_PORT + $i - 1))
  for attempt in $(seq 1 30); do
    if curl -s http://localhost:$PORT/api/archivist/v1/debug/info >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
done

# Set availability on provider nodes (all except bootstrap)
echo "      Setting availability on provider nodes..."
for i in $(seq 2 $NUM_NODES); do
  PORT=$(($BASE_API_PORT + $i - 1))
  curl -s -o /dev/null -X POST http://localhost:$PORT/api/archivist/v1/sales/availability \
    -H "Content-Type: application/json" \
    -d '{"minimumPricePerBytePerSecond":"1","maximumCollateralPerByte":"100","maximumDuration":"86400"}'
done
echo "      Availability set"

# ============================================================
# READY: Test execution
# ============================================================
echo ""
echo "[5/5] Cluster ready!"
echo ""
echo "========================================"
echo "E2E TEST ENVIRONMENT"
echo "========================================"
echo "Prometheus: http://localhost:9090"
echo "Grafana:    http://localhost:3000 (admin/admin)"
echo ""
echo "Node endpoints:"
for i in $(seq 1 $NUM_NODES); do
  PORT=$(($BASE_API_PORT + $i - 1))
  echo "  Node $i: http://localhost:$PORT"
done
echo ""
echo "Log files: /tmp/archivist-e2e/node{1..$NUM_NODES}/logs/"
echo ""
echo "To run test:"
echo "  # Upload test file to Node 1"
echo "  dd if=/dev/urandom of=/tmp/testdata.bin bs=1M count=100"
echo '  CID=$(curl -s -X POST -H "Content-Type: application/octet-stream" --data-binary @/tmp/testdata.bin http://localhost:'"$BASE_API_PORT"'/api/archivist/v1/data | jq -r ".cid")'
echo ""
echo "========================================"

# Cleanup on exit (unless DEBUG=1)
if [ -z "$DEBUG" ]; then
  trap "echo 'Cleaning up...'; kill $HARDHAT_PID $NODE1_PID 2>/dev/null; pkill -f 'archivist.*e2e' 2>/dev/null; rm -rf /tmp/archivist-e2e/" EXIT
else
  trap "kill $HARDHAT_PID $NODE1_PID 2>/dev/null; pkill -f 'archivist.*e2e' 2>/dev/null" EXIT
  echo "DEBUG: Data preserved in /tmp/archivist-e2e/"
fi

# Keep running
echo "Press Ctrl+C to stop and cleanup..."
wait
