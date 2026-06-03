#!/bin/bash
# Multi-peer measurement v2 — richer metrics + warm-up omission.
#
# Differences from measure_multipeer.sh:
#   * iperf3 warm-up: -O omits the first WARMUP seconds from throughput stats.
#   * One combined bpftrace script reports, per second:
#       - wasted GRO polls   (wg_packet_rx_poll retval == 0)
#       - useful GRO polls    (retval > 0)
#       - NET_RX_SOFTIRQ time in ns  (the quantity the paper says collapses)
#     and, at exit, a histogram of work_done (delivery batch size = effective
#     queue depth at delivery).
#   * Ping is run non-quiet at 20 Hz so per-packet RTTs survive for percentile
#     analysis (p50/p99/p99.9) in analyze_runs.py.
#
# Usage: sudo bash measure_multipeer_v2.sh <label> <N> <results_dir> [duration]
#   label        free-form tag stored in info.txt
#   N            number of client peers
#   results_dir  exact directory to write into (created if missing)
#   duration     total iperf3 seconds incl. warm-up (default 60)
set -eo pipefail

LABEL=${1:-run}
N=${2:-8}
RESULTS_DIR=${3:?results_dir required}
DURATION=${4:-60}
WARMUP=5
STREAMS=${STREAMS:-4}   # per client; total = N * STREAMS. Override via env (run_improved.sh).

mkdir -p "$RESULTS_DIR"

{
    echo "=== measure v2: $LABEL, $N clients x $STREAMS streams ==="
    echo "kernel: $(uname -r)"
    echo "loaded_module: $(lsmod | grep '^wireguard' | head -1)"
    echo "label: $LABEL"
    echo "clients: $N"
    echo "streams_per_client: $STREAMS"
    echo "total_streams: $((N * STREAMS))"
    echo "duration_s: $DURATION"
    echo "warmup_omit_s: $WARMUP"
    P_FIX=/sys/module/wireguard/parameters/wg_eoi_fix
    P_DELAY=/sys/module/wireguard/parameters/wg_decrypt_delay_us
    echo "wg_eoi_fix: $( [ -r "$P_FIX" ] && cat "$P_FIX" || echo n/a )"
    echo "wg_decrypt_delay_us: $( [ -r "$P_DELAY" ] && cat "$P_DELAY" || echo n/a )"
    echo "online_cpus: $(grep -c '1' /sys/devices/system/cpu/cpu[0-9]*/online 2>/dev/null || nproc) (approx)"
    echo "nproc_online: $(nproc)"
} > "$RESULTS_DIR/info.txt"

# ── iperf3 servers (one per client, distinct ports) ───────────────────────────
echo "[1/5] Starting $N iperf3 servers..."
for i in $(seq 0 $((N-1))); do
    PORT=$((5201 + i))
    sudo ip netns exec ns_mp_server iperf3 -s -p $PORT --one-off \
        > "$RESULTS_DIR/iperf3_server_${i}.json" 2>&1 &
done
sleep 1

# ── Combined bpftrace probe: GRO counts + NET_RX softirq time + batch hist ────
# vec 3 == NET_RX_SOFTIRQ.
echo "[2/5] Starting bpftrace (GRO + NET_RX softirq time + batch histogram)..."
sudo bpftrace -e '
  kretprobe:wg_packet_rx_poll /retval == 0/ { @wasted += 1; }
  kretprobe:wg_packet_rx_poll /retval > 0/  { @useful += 1; @batch = lhist(retval, 0, 64, 4); }
  tracepoint:irq:softirq_entry /args->vec == 3/ { @s[cpu] = nsecs; }
  tracepoint:irq:softirq_exit  /args->vec == 3 && @s[cpu] != 0/ {
      @netrx_ns += nsecs - @s[cpu]; @s[cpu] = 0;
  }
  interval:s:1 {
      printf("GRO %lld %lld NETRX_NS %lld\n", @wasted, @useful, @netrx_ns);
      @wasted = 0; @useful = 0; @netrx_ns = 0;
  }
  END { clear(@s); clear(@wasted); clear(@useful); clear(@netrx_ns); print(@batch); }
' > "$RESULTS_DIR/bpftrace_raw.txt" 2>&1 &
BPFTRACE_PID=$!
sleep 2

# ── /proc/softirqs NET_RX snapshot (cheap cross-check) ────────────────────────
grep -E '^\s*NET_RX' /proc/softirqs > "$RESULTS_DIR/softirqs_before.txt" 2>/dev/null || true

# ── iperf3 clients ────────────────────────────────────────────────────────────
echo "[3/5] Launching $N iperf3 clients ($DURATION s, omit ${WARMUP}s)..."
CLIENT_PIDS=()
for i in $(seq 0 $((N-1))); do
    PORT=$((5201 + i))
    sudo ip netns exec ns_mp_client_${i} \
        iperf3 -c 10.99.0.1 -p $PORT -t $DURATION -O $WARMUP -P $STREAMS \
        --json > "$RESULTS_DIR/iperf3_client_${i}.json" 2>&1 &
    CLIENT_PIDS+=($!)
done

# ── Latency: 20 Hz ping, non-quiet so per-packet RTTs are kept ────────────────
echo "[4/5] Starting 20 Hz ping latency probe from ns_mp_client_0..."
PING_COUNT=$(( (DURATION - WARMUP) * 20 ))
sudo ip netns exec ns_mp_client_0 \
    ping -i 0.05 -c "$PING_COUNT" 10.99.0.1 > "$RESULTS_DIR/ping_latency.txt" 2>&1 &
PING_PID=$!

wait "${CLIENT_PIDS[@]}" 2>/dev/null || true
wait $PING_PID 2>/dev/null || true

echo "[5/5] Stopping bpftrace..."
grep -E '^\s*NET_RX' /proc/softirqs > "$RESULTS_DIR/softirqs_after.txt" 2>/dev/null || true
sudo kill "$BPFTRACE_PID" 2>/dev/null || true
sleep 1

echo "  done -> $RESULTS_DIR"
