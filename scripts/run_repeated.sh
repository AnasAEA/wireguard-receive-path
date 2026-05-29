#!/bin/bash
# Repeated, variance-controlled stock-vs-patched comparison.
#
# Runs RUNS iterations of {stock, patched} at N peers, each iteration a fresh
# module load + tunnel setup + measurement, under variance control (E-cores
# offlined, performance governor). All runs land in one parent directory so
# analyze_runs.py can compute medians and latency percentiles across them.
#
# Usage:
#   sudo bash run_repeated.sh [N] [RUNS] [DURATION] [MODE] [KEEP_CPUS]
#     N         peers (default 32)
#     RUNS      iterations per module (default 10)
#     DURATION  iperf3 seconds incl. warm-up (default 60)
#     MODE      ecores  -> offline efficiency cores only (default; clean baseline)
#               bottleneck -> keep only KEEP_CPUS online (force contention)
#     KEEP_CPUS quoted CPU list for bottleneck mode (default "0 1")
#
# Examples:
#   sudo bash run_repeated.sh 32 10 60                 # clean variance-controlled
#   sudo bash run_repeated.sh 32 10 60 bottleneck "0 1"  # 2-core contention
set -eo pipefail

N=${1:-32}
RUNS=${2:-10}
DURATION=${3:-60}
MODE=${4:-ecores}
KEEP_CPUS=${5:-"0 1"}

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS/tuning.sh"

STAMP=$(date +%Y%m%d_%H%M%S)
PARENT="$SCRIPTS/../results/repeated_${STAMP}_mp${N}_${MODE}"
mkdir -p "$PARENT"

echo "============================================================"
echo "  Repeated comparison: N=$N peers, RUNS=$RUNS, DURATION=${DURATION}s"
echo "  mode=$MODE   parent=$PARENT"
echo "============================================================"

cleanup() {
    bash "$SCRIPTS/teardown_multipeer.sh" "$N" 2>/dev/null || true
    tuning_restore
}
trap cleanup EXIT

# Apply variance control once for the whole sweep.
if [ "$MODE" = "bottleneck" ]; then
    tuning_leave_only $KEEP_CPUS
else
    tuning_apply
fi

run_one() {
    local module=$1 load_script=$2 run_idx=$3
    local label rdir
    label=$(printf "%s" "$module")
    rdir="$PARENT/$(printf 'run%02d_%s' "$run_idx" "$module")"
    echo ""
    echo "---- run $run_idx / $RUNS : $module ----"
    bash "$SCRIPTS/$load_script"
    bash "$SCRIPTS/setup_multipeer.sh" "$N"
    bash "$SCRIPTS/measure_multipeer_v2.sh" "$label" "$N" "$rdir" "$DURATION"
    bash "$SCRIPTS/teardown_multipeer.sh" "$N"
}

for r in $(seq 1 "$RUNS"); do
    run_one stock   load_stock.sh   "$r"
    run_one patched load_patched.sh "$r"
done

echo ""
echo "============================================================"
echo "  All runs done. Analyzing..."
echo "============================================================"
python3 "$SCRIPTS/analyze_runs.py" "$PARENT" "$DURATION" | tee "$PARENT/SUMMARY.md"
echo ""
echo "Summary written to: $PARENT/SUMMARY.md"
