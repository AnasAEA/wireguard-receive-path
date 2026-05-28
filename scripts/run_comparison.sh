#!/bin/bash
# Full stock vs patched comparison in one shot.
# Runs: load stock → setup tunnel → measure → teardown →
#        load patched → setup tunnel → measure → teardown → print comparison
set -e

SCRIPTS="$(dirname "$0")"

run_one() {
    local label=$1
    local load_script=$2

    echo ""
    echo "============================================"
    echo "  $label"
    echo "============================================"
    bash "$load_script"
    bash "$SCRIPTS/setup_tunnel.sh"
    bash "$SCRIPTS/measure.sh" "$label"
    bash "$SCRIPTS/teardown_tunnel.sh"
}

run_one "stock"   "$SCRIPTS/load_stock.sh"
run_one "patched" "$SCRIPTS/load_patched.sh"

echo ""
echo "============================================"
echo "  Comparison complete. Results in results/"
echo "============================================"
ls -lt "$SCRIPTS/../results/" | head -10
