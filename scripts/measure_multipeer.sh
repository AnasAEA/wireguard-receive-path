#!/bin/bash
# Multi-peer measurement: N clients all hammering one server simultaneously.
# This is the paper's scenario: many peers sharing one packet_crypt_wq.
#
# Usage: sudo bash measure_multipeer.sh [label] [N]
set -eo pipefail
set +e; command -v mpstat >/dev/null 2>&1 && HAS_MPSTAT=1 || HAS_MPSTAT=0; set -e

LABEL=${1:-"run"}
N=${2:-8}
DURATION=30
STREAMS=4   # streams per client; total = N * STREAMS

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPO_DIR="$(dirname "$0")/.."
RESULTS_DIR="$REPO_DIR/results/${TIMESTAMP}_${LABEL}_mp${N}"
mkdir -p "$RESULTS_DIR"

echo "=== Multi-peer measurement: $LABEL, $N clients × $STREAMS streams @ $TIMESTAMP ===" \
    | tee "$RESULTS_DIR/info.txt"
{
    echo "kernel: $(uname -r)"
    echo "module: $(modinfo wireguard 2>/dev/null | grep filename || echo unknown)"
    echo "label: $LABEL"
    echo "clients: $N"
    echo "streams_per_client: $STREAMS"
    echo "total_streams: $((N * STREAMS))"
    echo "duration: ${DURATION}s"
} >> "$RESULTS_DIR/info.txt"

# ── Start iperf3 servers (one per client, different ports) ────────────────────
echo "[1/5] Starting $N iperf3 servers in ns_mp_server..."
for i in $(seq 0 $((N-1))); do
    PORT=$((5201 + i))
    sudo ip netns exec ns_mp_server iperf3 -s -p $PORT --one-off \
        > "$RESULTS_DIR/iperf3_server_${i}.json" 2>&1 &
done
sleep 1

# ── Start bpftrace: GRO polls ─────────────────────────────────────────────────
echo "[2/5] Starting bpftrace GRO probe..."
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

# ── Launch iperf3 clients + optional mpstat ───────────────────────────────────
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

# ── Ping latency from client_0 during traffic ─────────────────────────────────
echo "[4/5] Starting ping latency probe from ns_mp_client_0..."
sudo ip netns exec ns_mp_client_0 \
    ping -i 0.1 -c 250 -q 10.99.0.1 > "$RESULTS_DIR/ping_latency.txt" 2>&1 &
PING_PID=$!

# ── Start wg-crypt specific CSW probe 3s into traffic (after kworkers spawn) ──
# bpftrace comm =~ regex not supported here; use PID-based filter instead.
sleep 3
WG_PIDS=$(grep -rl "wg-crypt" /proc/[0-9]*/comm 2>/dev/null \
    | sed 's|/proc/\([0-9]*\)/comm|\1|' | tr '\n' ' ' | sed 's/ $//' || true)
CSW_PID=""
if [ -n "$WG_PIDS" ]; then
    PID_FILTER=$(echo $WG_PIDS | tr ' ' '\n' \
        | awk '{printf "pid == %s || ", $1}' | sed 's/ || $//')
    echo "wg-crypt kworker PIDs: $WG_PIDS" >> "$RESULTS_DIR/info.txt"
    sudo bpftrace -e "
      software:context-switches:1 / $PID_FILTER / { @csw += 1; }
      software:cpu-migrations:1   / $PID_FILTER / { @mig += 1; }
      interval:s:1 {
        printf(\"%lld %lld\n\", @csw, @mig);
        @csw = 0; @mig = 0;
      }
    " > "$RESULTS_DIR/bpftrace_csw.txt" 2>&1 &
    CSW_PID=$!
else
    echo "(no wg-crypt kworkers found — skipping CSW probe)" \
        > "$RESULTS_DIR/bpftrace_csw.txt"
fi

# Wait for iperf3 clients and ping to finish
wait "${CLIENT_PIDS[@]}" 2>/dev/null || true
wait $PING_PID 2>/dev/null || true

echo "[5/5] Stopping bpftrace..."
sudo kill $BPFTRACE_PID 2>/dev/null || true
[ -n "$CSW_PID" ] && sudo kill $CSW_PID 2>/dev/null || true
[ -n "$MPSTAT_PID" ] && wait $MPSTAT_PID 2>/dev/null || true
sleep 1

# ── Summarize ────────────────────────────────────────────────────────────────
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

CSW_SUMMARY=$(awk '
    NF==2 { c+=$1; m+=$2; n++ }
    END {
        if (n>0) printf "csw_avg=%.0f/s  mig_avg=%.0f/s", c/n, m/n
        else print "no data"
    }
' "$RESULTS_DIR/bpftrace_csw.txt" 2>/dev/null)

LATENCY_SUMMARY=$(grep -E "min/avg/max" "$RESULTS_DIR/ping_latency.txt" 2>/dev/null \
    | sed 's/.*= //' \
    | awk -F'[/]' '{ printf "min=%.3fms  avg=%.3fms  max=%.3fms  mdev=%.3fms", $1, $2, $3, $4 }' \
    || echo "no data")

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
echo "=== Results: $LABEL ($N clients) ==="
echo "  Total throughput : $TOTAL_BPS"
echo "  GRO              : $GRO_SUMMARY"
echo "  Context switches : $CSW_SUMMARY"
echo "  Latency (ping)   : $LATENCY_SUMMARY"
echo "  CPU softirq      : $CPU_SUMMARY"
echo ""

{
    echo ""
    echo "=== Summary ==="
    echo "total_throughput: $TOTAL_BPS"
    echo "gro: $GRO_SUMMARY"
    echo "csw: $CSW_SUMMARY"
    echo "latency: $LATENCY_SUMMARY"
    echo "cpu: $CPU_SUMMARY"
} >> "$RESULTS_DIR/info.txt"

echo "Full results saved to: $RESULTS_DIR"
