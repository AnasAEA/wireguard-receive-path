#!/bin/bash
# Measure CPU migrations specifically on wg-crypt kworker threads.
# Stock vs patched at N peers, 30-second window.
# PIDs collected via /proc scan 3s into traffic (after kworkers spawn).
#
# Usage: sudo bash run_wgcrypt_migration_comparison.sh [N]
set -eo pipefail

N=${1:-32}
DURATION=30
STREAMS=4
SCRIPTS="$(dirname "$0")"
REPO_DIR="$SCRIPTS/.."

run_one() {
    local LABEL=$1
    local TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    local RESULTS_DIR="$REPO_DIR/results/${TIMESTAMP}_${LABEL}_wgmig_mp${N}"
    mkdir -p "$RESULTS_DIR"

    echo ""
    echo "--- $LABEL: $N peers ---"
    echo "label: $LABEL  clients: $N  streams: $((N*STREAMS))" \
        | tee "$RESULTS_DIR/info.txt"

    # Start iperf3 servers
    for i in $(seq 0 $((N-1))); do
        sudo ip netns exec ns_mp_server iperf3 -s -p $((5201+i)) --one-off \
            > "$RESULTS_DIR/iperf3_server_${i}.json" 2>&1 &
    done
    sleep 1

    # Start iperf3 clients
    CLIENT_PIDS=()
    for i in $(seq 0 $((N-1))); do
        sudo ip netns exec ns_mp_client_${i} \
            iperf3 -c 10.99.0.1 -p $((5201+i)) -t $DURATION -P $STREAMS \
            --json > "$RESULTS_DIR/iperf3_client_${i}.json" 2>&1 &
        CLIENT_PIDS+=($!)
    done

    # Wait for kworkers to fully spawn under load (patched module may need extra time)
    sleep 5

    # Collect wg-crypt PIDs via /proc comm (ps column truncates; /proc does not)
    # || true: grep returns 1 when no matches; must not trigger set -e
    WG_PIDS=$(grep -rl "wg-crypt" /proc/[0-9]*/comm 2>/dev/null \
        | sed 's|/proc/\([0-9]*\)/comm|\1|' | tr '\n' ' ' | sed 's/ $//' || true)

    echo "wg-crypt PIDs found: $(echo $WG_PIDS | wc -w)" | tee -a "$RESULTS_DIR/info.txt"
    echo "pids: $WG_PIDS" >> "$RESULTS_DIR/info.txt"

    BPFTRACE_PID=""
    if [ -n "$WG_PIDS" ]; then
        PID_FILTER=$(echo $WG_PIDS | tr ' ' '\n' \
            | awk '{printf "pid == %s || ", $1}' | sed 's/ || $//')
        sudo bpftrace -e "
          software:cpu-migrations:1 / $PID_FILTER / { @mig += 1; }
          interval:s:1 {
            printf(\"%lld\n\", @mig);
            @mig = 0;
          }
        " > "$RESULTS_DIR/bpftrace_mig.txt" 2>&1 &
        BPFTRACE_PID=$!
    else
        echo "WARNING: no wg-crypt kworkers found" | tee -a "$RESULTS_DIR/info.txt"
        echo "no data" > "$RESULTS_DIR/bpftrace_mig.txt"
    fi

    # Wait for clients
    wait "${CLIENT_PIDS[@]}" 2>/dev/null || true
    [ -n "$BPFTRACE_PID" ] && sudo kill $BPFTRACE_PID 2>/dev/null || true
    sleep 1

    # Summarize
    TOTAL_BPS=$(python3 -c "
import json, glob
total = 0
for f in glob.glob('$RESULTS_DIR/iperf3_client_*.json'):
    try:
        d = json.load(open(f))
        total += d['end']['sum_received']['bits_per_second']
    except: pass
print(f'{total/1e9:.3f} Gbits/sec')
" 2>/dev/null)

    MIG_SUMMARY=$(awk '/^[0-9]/ { m+=$1; n++ }
        END { if (n>0) printf "mig_avg=%.1f/s  n_samples=%d", m/n, n;
              else print "no data" }' \
        "$RESULTS_DIR/bpftrace_mig.txt" 2>/dev/null)

    echo "throughput: $TOTAL_BPS" | tee -a "$RESULTS_DIR/info.txt"
    echo "wgcrypt_migrations: $MIG_SUMMARY" | tee -a "$RESULTS_DIR/info.txt"
    echo ""
    echo "  Throughput : $TOTAL_BPS"
    echo "  Migrations : $MIG_SUMMARY"
    echo "  Results    : $RESULTS_DIR"
}

echo "=========================================="
echo " wg-crypt migration comparison: $N peers"
echo "=========================================="

# ── Stock ──────────────────────────────────────────────────────────────────────
sudo bash "$SCRIPTS/load_stock.sh"
sleep 1
sudo bash "$SCRIPTS/setup_multipeer.sh" $N
sleep 2
run_one "stock"
sudo bash "$SCRIPTS/teardown_multipeer.sh" $N
sudo rmmod wireguard 2>/dev/null || true
sleep 2

# ── Patched ────────────────────────────────────────────────────────────────────
sudo bash "$SCRIPTS/load_patched.sh"
sleep 1
sudo bash "$SCRIPTS/setup_multipeer.sh" $N
sleep 2
run_one "patched"
sudo bash "$SCRIPTS/teardown_multipeer.sh" $N
sudo rmmod wireguard 2>/dev/null || true

echo ""
echo "=========================================="
echo " Done. Compare the migration counts above."
echo "=========================================="
