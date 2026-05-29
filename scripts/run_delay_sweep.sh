#!/bin/bash
# Decrypt-delay sweep: find the per-packet decrypt cost at which EoI starts to
# hurt throughput, comparing stock behavior (wg_eoi_fix=0) against the fix
# (wg_eoi_fix=1) from a single delay-capable module.
#
# Requires the module built from admin/PATCH_DECRYPT_DELAY.md, which exposes:
#   /sys/module/wireguard/parameters/wg_decrypt_delay_us
#   /sys/module/wireguard/parameters/wg_eoi_fix
#
# WireGuard is constrained to a small core set (default 2) to force contention.
# One tunnel stays up for the whole sweep; only the sysfs knobs change between
# cells, so no reload/teardown is needed mid-sweep.
#
# Usage:
#   sudo bash run_delay_sweep.sh [N] [DURATION] [KEEP_CPUS] [DELAYS]
#     N          peers (default 16)
#     DURATION   seconds per cell (default 30)
#     KEEP_CPUS  quoted CPU list kept online (default "0 1")
#     DELAYS     quoted us list to sweep (default "0 5 10 20 40 80")
set -eo pipefail

N=${1:-16}
DURATION=${2:-30}
KEEP_CPUS=${3:-"0 1"}
DELAYS=${4:-"0 5 10 20 40 80"}

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS/tuning.sh"

PARAM_DELAY=/sys/module/wireguard/parameters/wg_decrypt_delay_us
PARAM_FIX=/sys/module/wireguard/parameters/wg_eoi_fix

STAMP=$(date +%Y%m%d_%H%M%S)
PARENT="$SCRIPTS/../results/sweep_${STAMP}_mp${N}"
mkdir -p "$PARENT"
CSV="$PARENT/SWEEP.csv"
echo "delay_us,fix,tput_gbps,wasted_s,useful_s,total_s,netrx_ms_s,p50_ms,p99_ms,p999_ms,max_ms" > "$CSV"

cleanup() {
    bash "$SCRIPTS/teardown_multipeer.sh" "$N" 2>/dev/null || true
    [ -w "$PARAM_DELAY" ] && echo 0 | sudo tee "$PARAM_DELAY" >/dev/null 2>&1 || true
    [ -w "$PARAM_FIX" ] && echo 1 | sudo tee "$PARAM_FIX" >/dev/null 2>&1 || true
    tuning_restore
}
trap cleanup EXIT

# Load the delay-capable patched module and verify the knobs exist.
bash "$SCRIPTS/load_patched.sh"
if [ ! -w "$PARAM_DELAY" ] || [ ! -w "$PARAM_FIX" ]; then
    echo "ERROR: $PARAM_DELAY / $PARAM_FIX missing."
    echo "The loaded module was not built from admin/PATCH_DECRYPT_DELAY.md."
    exit 1
fi

tuning_leave_only $KEEP_CPUS
bash "$SCRIPTS/setup_multipeer.sh" "$N"

for d in $DELAYS; do
    echo "$d" | sudo tee "$PARAM_DELAY" >/dev/null
    for fix in 0 1; do
        echo "$fix" | sudo tee "$PARAM_FIX" >/dev/null
        echo ""
        echo "==== delay=${d}us  fix=${fix}  (N=$N, keep=[$KEEP_CPUS]) ===="
        sleep 1  # let the knob take effect on in-flight workers
        rdir="$PARENT/$(printf 'd%03d_fix%d' "$d" "$fix")"
        bash "$SCRIPTS/measure_multipeer_v2.sh" "d${d}_fix${fix}" "$N" "$rdir" "$DURATION"
        row=$(python3 "$SCRIPTS/analyze_one.py" "$rdir")
        echo "$d,$fix,$row" >> "$CSV"
    done
done

bash "$SCRIPTS/teardown_multipeer.sh" "$N"

echo ""
echo "============================================================"
echo "  Sweep complete. CSV: $CSV"
echo "============================================================"
column -t -s, "$CSV"
