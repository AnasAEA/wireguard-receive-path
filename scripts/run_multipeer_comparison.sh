#!/bin/bash
# Full multi-peer stock vs patched comparison.
# Usage: sudo bash run_multipeer_comparison.sh [N]
set -e

N=${1:-8}
SCRIPTS="$(dirname "$0")"

run_one() {
    local label=$1
    local load_script=$2

    echo ""
    echo "============================================"
    echo "  $label  ($N peers)"
    echo "============================================"
    bash "$load_script"
    bash "$SCRIPTS/setup_multipeer.sh" "$N"
    bash "$SCRIPTS/measure_multipeer.sh" "$label" "$N"
    bash "$SCRIPTS/teardown_multipeer.sh" "$N"
}

run_one "stock_mp"   "$SCRIPTS/load_stock.sh"
run_one "patched_mp" "$SCRIPTS/load_patched.sh"

echo ""
echo "============================================"
echo "  Multi-peer comparison complete."
echo "============================================"
ls -lt "$SCRIPTS/../results/" | grep "_mp${N}" | head -6
