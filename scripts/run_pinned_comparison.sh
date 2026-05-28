#!/bin/bash
# Full pinned comparison: stock vs patched WireGuard with all workers on one CPU.
# This replicates the paper's saturation condition on a single machine.
#
# Usage: sudo bash run_pinned_comparison.sh [N] [cpu]
#   N:   number of peers (default: 16)
#   cpu: CPU to pin workers to (default: 0)
set -eo pipefail

N=${1:-16}
PIN_CPU=${2:-0}
SCRIPTS="$(dirname "$0")"

echo "=========================================="
echo " Pinned comparison: $N peers, CPU $PIN_CPU"
echo "=========================================="
echo ""

# ── Stock run ─────────────────────────────────────────────────────────────────
echo ">>> Loading stock WireGuard..."
sudo bash "$SCRIPTS/load_stock.sh"
sleep 1

echo ">>> Setting up $N-peer topology (stock)..."
sudo bash "$SCRIPTS/setup_multipeer.sh" $N
sleep 2

echo ">>> Running stock measurement (pinned, $N peers)..."
sudo bash "$SCRIPTS/measure_multipeer_pinned.sh" "stock_pinned" $N $PIN_CPU

echo ">>> Tearing down topology..."
sudo bash "$SCRIPTS/teardown_multipeer.sh" $N

echo ">>> Unloading stock WireGuard..."
sudo rmmod wireguard 2>/dev/null || true
sleep 2

# ── Patched run ───────────────────────────────────────────────────────────────
echo ""
echo ">>> Loading patched WireGuard..."
sudo bash "$SCRIPTS/load_patched.sh"
sleep 1

echo ">>> Setting up $N-peer topology (patched)..."
sudo bash "$SCRIPTS/setup_multipeer.sh" $N
sleep 2

echo ">>> Running patched measurement (pinned, $N peers)..."
sudo bash "$SCRIPTS/measure_multipeer_pinned.sh" "patched_pinned" $N $PIN_CPU

echo ">>> Tearing down topology..."
sudo bash "$SCRIPTS/teardown_multipeer.sh" $N

echo ">>> Unloading patched WireGuard..."
sudo rmmod wireguard 2>/dev/null || true
sleep 2

echo ""
echo "=========================================="
echo " Pinned comparison complete."
echo " Results:"
ls -lt "$SCRIPTS/../results/" | grep "_pinned" | head -6
echo "=========================================="
