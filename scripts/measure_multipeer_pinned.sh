#!/bin/bash
# Multi-peer measurement with WireGuard workers pinned to a single CPU.
# Replicates the paper's saturation condition: all decrypt work + GRO softirq
# compete on one core, creating the feedback loop that collapses throughput.
#
# Usage: sudo bash measure_multipeer_pinned.sh [label] [N] [cpu]
#   label: run label (default: run)
#   N:     number of peers (default: 16)
#   cpu:   CPU to pin workers to (default: 0)
set -eo pipefail
set +e; command -v mpstat >/dev/null 2>&1 && HAS_MPSTAT=1 || HAS_MPSTAT=0; set -e

LABEL=${1:-"run"}
N=${2:-16}
PIN_CPU=${3:-0}
DURATION=30
STREAMS=4

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPO_DIR="$(dirname "$0")/.."
RESULTS_DIR="$REPO_DIR/results/${TIMESTAMP}_${LABEL}_mp${N}_pinned"
mkdir -p "$RESULTS_DIR"

WQ_NAME="wg-crypt-wg_mp_server"
SCRIPTS_DIR="$(dirname "$0")"

echo "=== Multi-peer PINNED measurement: $LABEL, $N clients × $STREAMS streams, CPU=$PIN_CPU @ $TIMESTAMP ===" \
    | tee "$RESULTS_DIR/info.txt"
{
    echo "kernel: $(uname -r)"
    echo "module: $(modinfo wireguard 2>/dev/null | grep filename || echo unknown)"
    echo "label: $LABEL"
    echo "clients: $N"
    echo "streams_per_client: $STREAMS"
    echo "total_streams: $((N * STREAMS))"
    echo "duration: ${DURATION}s"
    echo "pinned_cpu: $PIN_CPU"
} >> "$RESULTS_DIR/info.txt"

# ── Start iperf3 servers ──────────────────────────────────────────────────────
echo "[1/5] Starting $N iperf3 servers in ns_mp_server..."
for i in $(seq 0 $((N-1))); do
    PORT=$((5201 + i))
    sudo ip netns exec ns_mp_server iperf3 -s -p $PORT --one-off \
        > "$RESULTS_DIR/iperf3_server_${i}.json" 2>&1 &
done
sleep 1

# ── Start bpftrace ────────────────────────────────────────────────────────────
echo "[2/5] Starting bpftrace..."
sudo bpftrace -e '
  kretprobe:wg_packet_rx_poll /retval == 0/ { @wasted_gro += 1; }
  kretprobe:wg_packet_rx_poll /retval > 0/  { @useful_gro += 1; }
  interval:s:1 {
    printf("%lld %lld\n", @wasted_gro, @useful_gro);
    @wasted_gro = 0; @useful_gro = 0;
  }
' > "$RESULTS_DIR/bpftrace_raw.txt" 2>&1 &
BPFTRACE_PID=$!
sleep 2

# ── Launch iperf3 clients ─────────────────────────────────────────────────────
echo "[3/5] Launching $N iperf3 clients..."
MPSTAT_PID=""
if [ "$HAS_MPSTAT" = "1" ]; then
    mpstat -P ALL 1 $DURATION > "$RESULTS_DIR/mpstat_raw.txt" 2>&1 &
    MPSTAT_PID=$!
else
    echo "(mpstat not found — skipping)" > "$RESULTS_DIR/mpstat_raw.txt"
fi

CLIENT_PIDS=()
for i in $(seq 0 $((N-1))); do
    PORT=$((5201 + i))
    sudo ip netns exec ns_mp_client_${i} \
        iperf3 -c 10.99.0.1 -p $PORT -t $DURATION -P $STREAMS \
        --json > "$RESULTS_DIR/iperf3_client_${i}.json" 2>&1 &
    CLIENT_PIDS+=($!)
done

# ── Pin workers 2s after traffic starts (catches newly spawned kworkers) ──────
echo "[4/5] Pinning WireGuard workers to CPU $PIN_CPU (after 2s warmup)..."
sleep 2
PIDS=$(ps -eo pid,comm | awk -v wq="$WQ_NAME" '$2 ~ wq {print $1}')
if [ -n "$PIDS" ]; then
    for pid in $PIDS; do
        sudo taskset -cp $PIN_CPU $pid 2>/dev/null \
            && echo "  Pinned PID $pid to CPU $PIN_CPU ($(ps -p $pid -o comm= 2>/dev/null))"
    done
    echo "$PIDS" | wc -w >> "$RESULTS_DIR/info.txt"
    echo "pinned_pids: $PIDS" >> "$RESULTS_DIR/info.txt"
else
    echo "  WARNING: no $WQ_NAME kworkers found to pin" | tee -a "$RESULTS_DIR/info.txt"
fi

# Wait for clients to finish
wait "${CLIENT_PIDS[@]}" 2>/dev/null || true

echo "[5/5] Stopping bpftrace and mpstat..."
sudo kill $BPFTRACE_PID 2>/dev/null
[ -n "$MPSTAT_PID" ] && wait $MPSTAT_PID 2>/dev/null || true
sleep 1

# ── Summarize ─────────────────────────────────────────────────────────────────
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

GRO_SUMMARY=$(awk '
    NF==2 { w+=$1; u+=$2; n++ }
    END {
        if (n>0 && (w+u)>0)
            printf "wasted_avg=%.0f/s  useful_avg=%.0f/s  waste_pct=%.1f%%",
                w/n, u/n, 100*w/(w+u)
        else print "no data"
    }
' "$RESULTS_DIR/bpftrace_raw.txt" 2>/dev/null)

CPU_SUMMARY=$(awk '
    /^[0-9]/ && $3 ~ /^[0-9]/ {
        cpu=$3; soft=$10+0
        if (soft > max[cpu]) max[cpu]=soft
        sum[cpu]+=soft; count[cpu]++
    }
    END {
        max_soft=0; max_cpu=""
        for (c in max) if (max[c]>max_soft) { max_soft=max[c]; max_cpu=c }
        avg_soft=0; n=0
        for (c in sum) { avg_soft+=sum[c]/count[c]; n++ }
        if (n>0) avg_soft/=n
        printf "peak_softirq_cpu=%s(%.1f%%)  avg_softirq_all_cpus=%.1f%%", max_cpu, max_soft, avg_soft
    }
' "$RESULTS_DIR/mpstat_raw.txt" 2>/dev/null)

echo ""
echo "=== Results: $LABEL ($N clients, pinned to CPU $PIN_CPU) ==="
echo "  Total throughput : $TOTAL_BPS"
echo "  GRO              : $GRO_SUMMARY"
echo "  CPU softirq      : $CPU_SUMMARY"
echo ""

{
    echo ""
    echo "=== Summary ==="
    echo "total_throughput: $TOTAL_BPS"
    echo "gro: $GRO_SUMMARY"
    echo "cpu: $CPU_SUMMARY"
} >> "$RESULTS_DIR/info.txt"

# ── Restore CPU affinity ──────────────────────────────────────────────────────
echo "Restoring CPU affinity..."
bash "$SCRIPTS_DIR/unpin_wg_workers.sh" 2>/dev/null || true

echo "Full results saved to: $RESULTS_DIR"
