#!/bin/bash
# Cleanup script for E2E testing
# Usage: ./e2e/cleanup.sh

set -e

echo "Cleaning up E2E test artifacts..."

# Stop all archivist processes
echo "Stopping archivist processes..."
pkill -f 'archivist.*e2e' 2>/dev/null || true
pkill -f 'archivist' 2>/dev/null || true

# Stop Hardhat
echo "Stopping Hardhat..."
pkill -f 'hardhat' 2>/dev/null || true

# Wait for processes
sleep 3

# Remove data directories
echo "Removing data directories..."
rm -rf /tmp/archivist-e2e/

# Verify
echo ""
echo "Disk usage after cleanup:"
df -h /tmp 2>/dev/null || df -h

echo ""
echo "Cleanup complete!"
