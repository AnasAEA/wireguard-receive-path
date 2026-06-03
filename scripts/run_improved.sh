#!/bin/bash
# Improved EoI experiment — fixes the methodological gaps of the May 28 run.
#
# What is different from run_repeated.sh / the May 28 campaign:
#
#   1. FIXED TOTAL LOAD across the peer sweep. Offered load is held constant
#      (TOTAL_STREAMS total iperf3 streams) and split across peers, so each peer
#      drives TOTAL_STREAMS/peers streams. This separates "number of peers" from
#      "amount of traffic", which were entangled before (4 streams/peer meant
#      1 peer = 1.5 Gbps but 8 peers = 13 Gbps). The 1-peer cell now runs at full
#      load — the control that was missing.
#
#   2. IN-MODULE FIX TOGGLE. If the loaded module exposes wg_eoi_fix
#      (built from admin/PATCH_DECRYPT_DELAY.md), stock vs patched is a sysfs
#      write, not a rmmod/insmod. Same module, same memory layout, same page
#      cache, same tunnel — a true apples-to-apples comparison with far less
#      variance. Falls back to load_stock.sh / load_patched.sh if the knob is
#      absent.
#
#   3. REPEATED, INTERLEAVED runs. RUNS iterations per cell; the stock/patched
#      order alternates each run so any slow drift cancels instead of biasing one
#      build. analyze_improved.py then reports medians + IQR.
#
#   4. OPTIONAL DECRYPT DELAY. DELAY_US > 0 (needs the knob from 2) emulates
#      heavier per-packet crypto, to push toward the throughput-collapse regime
#      the M1's fast NEON ChaCha20 cannot reach on its own.
#
# All cells land in one parent dir with a MANIFEST.csv that analyze_improved.py
# turns into a plot-ready summary.
#
# Usage:
#   sudo bash run_improved.sh [PEERS] [TOTAL_STREAMS] [RUNS] [DURATION] [DELAY_US] [MODE] [KEEP_CPUS]
#     PEERS         quoted peer-count list (default "1 2 4 8 16 32")
#     TOTAL_STREAMS total iperf3 streams held constant across the sweep (default 32)
#     RUNS          iterations per (peers, fix) cell (default 5)
#     DURATION      iperf3 seconds incl. warm-up (default 30)
#     DELAY_US      artificial per-packet decrypt delay, us (default 0; needs knob)
#     MODE          ecores (offline E-cores; default) | bottleneck (keep only KEEP_CPUS)
#     KEEP_CPUS     quoted CPU list for bottleneck mode (default "0 1")
#
# Examples:
#   sudo bash run_improved.sh                                  # full fixed-load sweep
#   sudo bash run_improved.sh "1 2 4 8 16 32" 32 5 30          # explicit, same as default
#   sudo bash run_improved.sh "16" 32 5 30 40 bottleneck "0 1" # regime test: 16 peers, 40us, 2 cores
set -eo pipefail

PEERS=${1:-"1 2 4 8 16 32"}
TOTAL_STREAMS=${2:-32}
RUNS=${3:-5}
DURATION=${4:-30}
DELAY_US=${5:-0}
MODE=${6:-ecores}
KEEP_CPUS=${7:-"0 1"}

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS/tuning.sh"

PARAM_FIX=/sys/module/wireguard/parameters/wg_eoi_fix
PARAM_DELAY=/sys/module/wireguard/parameters/wg_decrypt_delay_us

STAMP=$(date +%Y%m%d_%H%M%S)
PARENT="$SCRIPTS/../results/improved_${STAMP}_load${TOTAL_STREAMS}_${MODE}"
mkdir -p "$PARENT"
MANIFEST="$PARENT/MANIFEST.csv"
echo "peers,total_streams,per_client,delay_us,fix,run,rdir" > "$MANIFEST"

echo "============================================================"
echo "  Improved EoI sweep"
echo "  peers=[$PEERS]  total_streams=$TOTAL_STREAMS  runs=$RUNS  dur=${DURATION}s"
echo "  delay_us=$DELAY_US  mode=$MODE"
echo "  parent=$PARENT"
echo "============================================================"

# ── Decide comparison method: in-module toggle vs module reload ───────────────
# Load the patched module first; if it exposes the knob we use the fast path.
bash "$SCRIPTS/load_patched.sh" || true
USE_TOGGLE=0
if [ -w "$PARAM_FIX" ]; then
    USE_TOGGLE=1
    echo "[method] in-module toggle available (wg_eoi_fix) — no reloads between builds."
    if [ "$DELAY_US" -gt 0 ] && [ ! -w "$PARAM_DELAY" ]; then
        echo "ERROR: DELAY_US=$DELAY_US requested but wg_decrypt_delay_us knob is missing." >&2
        exit 1
    fi
else
    echo "[method] wg_eoi_fix knob absent — falling back to module reload per cell."
    if [ "$DELAY_US" -gt 0 ]; then
        echo "ERROR: DELAY_US needs the delay-capable module (admin/PATCH_DECRYPT_DELAY.md)." >&2
        exit 1
    fi
fi

cleanup() {
    # Best-effort teardown for whatever peer count was last set up.
    for p in $PEERS; do bash "$SCRIPTS/teardown_multipeer.sh" "$p" 2>/dev/null || true; done
    [ -w "$PARAM_DELAY" ] && echo 0 | sudo tee "$PARAM_DELAY" >/dev/null 2>&1 || true
    [ -w "$PARAM_FIX" ]   && echo 1 | sudo tee "$PARAM_FIX"   >/dev/null 2>&1 || true
    tuning_restore
}
trap cleanup EXIT

# ── Variance control, applied once for the whole sweep ────────────────────────
if [ "$MODE" = "bottleneck" ]; then
    tuning_leave_only $KEEP_CPUS
else
    tuning_apply
fi

# Set the decrypt delay once (constant across the sweep).
if [ -w "$PARAM_DELAY" ]; then echo "$DELAY_US" | sudo tee "$PARAM_DELAY" >/dev/null; fi

# fix=0 -> stock behavior, fix=1 -> patched (André's guard).
set_fix() {
    local fix=$1
    if [ "$USE_TOGGLE" = "1" ]; then
        echo "$fix" | sudo tee "$PARAM_FIX" >/dev/null
        sleep 1   # let in-flight workers observe the new value
    else
        if [ "$fix" = "0" ]; then bash "$SCRIPTS/load_stock.sh"; else bash "$SCRIPTS/load_patched.sh"; fi
    fi
}

measure_cell() {
    local peers=$1 per_client=$2 fix=$3 run=$4
    local mod rdir
    mod=$([ "$fix" = "1" ] && echo patched || echo stock)
    rdir="$PARENT/$(printf 'p%03d_%s_run%02d' "$peers" "$mod" "$run")"
    echo ""
    echo "---- peers=$peers  streams/peer=$per_client  $mod  run $run/$RUNS ----"
    set_fix "$fix"
    # When toggling in place the tunnel is already up; when reloading we must
    # rebuild it because rmmod destroyed the wg interfaces.
    if [ "$USE_TOGGLE" != "1" ] || [ "$NEED_SETUP" = "1" ]; then
        bash "$SCRIPTS/setup_multipeer.sh" "$peers"
        NEED_SETUP=0
    fi
    STREAMS="$per_client" bash "$SCRIPTS/measure_multipeer_v2.sh" "$mod" "$peers" "$rdir" "$DURATION"
    echo "$peers,$TOTAL_STREAMS,$per_client,$DELAY_US,$fix,$run,$rdir" >> "$MANIFEST"
}

for peers in $PEERS; do
    # Hold total offered load constant: split TOTAL_STREAMS across the peers.
    per_client=$(( TOTAL_STREAMS / peers ))
    [ "$per_client" -lt 1 ] && per_client=1

    if [ "$USE_TOGGLE" = "1" ]; then
        # One tunnel for this peer count; toggle fix between cells, no reload.
        bash "$SCRIPTS/setup_multipeer.sh" "$peers"
    else
        NEED_SETUP=1
    fi

    for run in $(seq 1 "$RUNS"); do
        # Alternate which build goes first each run so drift cancels.
        if [ $(( run % 2 )) -eq 1 ]; then order="0 1"; else order="1 0"; fi
        for fix in $order; do
            [ "$USE_TOGGLE" != "1" ] && NEED_SETUP=1
            measure_cell "$peers" "$per_client" "$fix" "$run"
        done
    done

    bash "$SCRIPTS/teardown_multipeer.sh" "$peers"
done

echo ""
echo "============================================================"
echo "  Sweep complete. Aggregating..."
echo "============================================================"
python3 "$SCRIPTS/analyze_improved.py" "$PARENT" | tee "$PARENT/SUMMARY.md"
echo ""
echo "Manifest : $MANIFEST"
echo "Summary  : $PARENT/SUMMARY.md  (+ SUMMARY.csv, runs_long.csv)"
echo "Next     : python3 $SCRIPTS/plot_improved.py $PARENT"
