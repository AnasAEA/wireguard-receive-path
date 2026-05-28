#!/bin/bash
# Run a full measurement: iperf3 throughput + bpftrace wasted GRO counter
# Usage: sudo ./measure.sh [label]
#   label: descriptive name, e.g. "stock" or "patched" (default: "run")
# Results saved to results/<timestamp>_<label>/

LABEL=${1:-"run"}
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPO_DIR="$(dirname "$0")/.."
RESULTS_DIR="$REPO_DIR/results/${TIMESTAMP}_${LABEL}"
mkdir -p "$RESULTS_DIR"

DURATION=30  # seconds of iperf3 traffic
STREAMS=8

echo "=== Measurement: $LABEL @ $TIMESTAMP ===" | tee "$RESULTS_DIR/info.txt"
{
    echo "kernel: $(uname -r)"
    echo "module: $(modinfo wireguard 2>/dev/null | grep filename || echo 'unknown')"
    echo "label: $LABEL"
    echo "duration: ${DURATION}s"
    echo "streams: $STREAMS"
    echo "timestamp: $TIMESTAMP"
} >> "$RESULTS_DIR/info.txt"

echo "[1/4] Starting iperf3 server in ns2..."
sudo ip netns exec ns2 iperf3 -s --one-off \
    --json > "$RESULTS_DIR/iperf3_server.json" 2>&1 &
SERVER_PID=$!
sleep 1

echo "[2/4] Starting bpftrace (wasted/useful GRO counter)..."
sudo bpftrace -e '
  kretprobe:wg_packet_rx_poll /retval == 0/ { @wasted_gro += 1; }
  kretprobe:wg_packet_rx_poll /retval > 0/  { @useful_gro += 1; }
  interval:s:1 {
    printf("%lld %lld\n", @wasted_gro, @useful_gro);
    @wasted_gro = 0; @useful_gro = 0;
  }
' > "$RESULTS_DIR/bpftrace_raw.txt" 2>&1 &
BPFTRACE_PID=$!
sleep 2  # let bpftrace attach before traffic starts

echo "[3/4] Running iperf3 client (${DURATION}s, ${STREAMS} streams)..."
sudo ip netns exec ns1 iperf3 -c 10.0.0.2 \
    -t $DURATION -P $STREAMS \
    --json > "$RESULTS_DIR/iperf3_client.json" 2>&1

echo "[4/4] Stopping bpftrace..."
sudo kill $BPFTRACE_PID 2>/dev/null
wait $SERVER_PID 2>/dev/null
sleep 1

# Summarize throughput from iperf3 JSON
THROUGHPUT=$(python3 -c "
import json, sys
try:
    d = json.load(open('$RESULTS_DIR/iperf3_client.json'))
    bps = d['end']['sum_received']['bits_per_second']
    print(f'{bps/1e9:.3f} Gbits/sec')
except Exception as e:
    print(f'parse error: {e}')
" 2>/dev/null)

# Summarize wasted GRO from bpftrace
GRO_SUMMARY=$(awk '
    NF==2 { w+=$1; u+=$2; n++ }
    END {
        if (n>0 && (w+u)>0)
            printf "wasted_avg=%.0f/s  useful_avg=%.0f/s  waste_pct=%.1f%%\n",
                w/n, u/n, 100*w/(w+u)
        else
            print "no data"
    }
' "$RESULTS_DIR/bpftrace_raw.txt" 2>/dev/null)

echo ""
echo "=== Results: $LABEL ==="
echo "  Throughput : $THROUGHPUT"
echo "  GRO        : $GRO_SUMMARY"
echo ""

{
    echo ""
    echo "=== Summary ==="
    echo "throughput: $THROUGHPUT"
    echo "gro: $GRO_SUMMARY"
} >> "$RESULTS_DIR/info.txt"

echo "Full results saved to: $RESULTS_DIR"
