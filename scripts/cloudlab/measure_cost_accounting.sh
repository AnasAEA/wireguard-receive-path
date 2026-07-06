#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# E10/E11 — cost-model confirmation + steering bound (2026-07-06, plan in
# CLOUDLAB_NEXT_STEPS.md). Two bounds, measured, no module changes:
#   E10a  perf cycle attribution, all cores, off vs both at delay 0 and 10us — symbol
#         shares of wg_packet_rx_poll / napi_complete_done / __napi_schedule vs total.
#   E10b  bpftrace duration SUMS for wg_packet_rx_poll (retval==0) — wasted poll time in
#         ns => CE, directly comparable to the Phase B CPU null.
#   E11   stall-episode gaps under off across delays: first retval==0 poll after a
#         productive poll opens an episode on that NAPI; next retval>0 poll closes it.
#         Raw gap = UPPER BOUND on delivery-blocked time (contains ~46% empty-queue
#         episodes — correct by the wg_diag 54/46 classifier; subtract T_decrypt floor
#         for the conservative recoverable-steering estimate).
# perf and bpftrace get SEPARATE windows (never concurrent — they'd perturb each other).
# Same capped bulk load as Phase B (2 Gb/s total over peers 1..N-1, genload_bulk.sh must
# already be on gen:/tmp — the decrypt sweep pushes it).
#   nohup sudo bash ~/measure_cost_accounting.sh > ~/costacct_run.log 2>&1 &
set -uo pipefail
exec 9>/tmp/costacct.lock
flock -n 9 || { echo "FATAL: another measure_cost_accounting.sh is running" >&2; exit 1; }
N=${1:-8}; GEN=${2:-gen}; NIC=${3:-enp6s0f0}
PERT=285; STREAMS=4                 # 2 Gb/s total / 7 bulk peers
E10_DELAYS="0 10000"; E11_DELAYS="0 2000 5000 10000"
PERF_DUR=15; BPF_DUR=30
TS=$(date +%Y%m%d_%H%M); OUT="$HOME/costacct_$TS"; mkdir -p "$OUT"
command -v perf >/dev/null || { echo "FATAL: perf not installed (apt install linux-tools-\$(uname -r))" >&2; exit 1; }

cleanup(){ local p
  for p in wg_supp wg_headwake wg_trig_k wg_decrypt_delay_ns; do
    echo 0 > /sys/module/wireguard/parameters/$p 2>/dev/null || true; done
  ethtool -N "$NIC" rx-flow-hash udp4 sd >/dev/null 2>&1 || true
  pkill -f 'iperf3 -s' 2>/dev/null || true; pkill bpftrace 2>/dev/null || true; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

set_cond(){ local s=0 h=0; [ "$1" = both ] && { s=1; h=1; }
  echo $s >/sys/module/wireguard/parameters/wg_supp
  echo 0  >/sys/module/wireguard/parameters/wg_trig_k
  echo $h >/sys/module/wireguard/parameters/wg_headwake; }

start_load(){ ssh -n -o StrictHostKeyChecking=no "$GEN" \
  "bash /tmp/genload_bulk.sh $N $1 $PERT $STREAMS" >/dev/null 2>&1 & }

cat > /tmp/e10b.bt <<'BT'
kprobe:wg_packet_rx_poll { @t[tid]=nsecs; }
kretprobe:wg_packet_rx_poll /@t[tid]/ {
  $d = nsecs - @t[tid]; delete(@t[tid]);
  @polls = count(); @poll_ns = sum($d);
  if (retval == 0) { @wasted = count(); @wasted_ns = sum($d); }
}
interval:s:30 { exit(); }
BT
cat > /tmp/e11.bt <<'BT'
kprobe:wg_packet_rx_poll { @n[tid]=arg0; @t[tid]=nsecs; }
kretprobe:wg_packet_rx_poll /@t[tid]/ {
  $napi = @n[tid]; $now = nsecs; delete(@n[tid]); delete(@t[tid]);
  if (retval == 0) {
    if (@ep[$napi] == 0) { @ep[$napi] = $now; }
  } else {
    if (@ep[$napi] != 0) {
      $g = ($now - @ep[$napi]) / 1000;
      @stall_us = hist($g); @stalls = count();
      @stall_sum_us = sum($g); @stall_max_us = max($g);
      @ep[$napi] = 0;
    }
  }
}
interval:s:30 { exit(); }
END { clear(@ep); clear(@n); clear(@t); }
BT

ethtool -N "$NIC" rx-flow-hash udp4 sdfn >/dev/null 2>&1
pkill -f 'iperf3 -s' 2>/dev/null; sleep 1
for i in $(seq 0 $((N-1))); do iperf3 -s -p $((5201+i)) -D; done
start_load 8; sleep 12   # warm-up burst (cold-start lesson, 2026-06-26)

{ echo "srcversion=$(cat /sys/module/wireguard/srcversion) date=$(date -Is) kernel=$(uname -r)"
  echo "gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
  ethtool -n "$NIC" rx-flow-hash udp4 2>/dev/null
} > "$OUT/meta.txt"

for D in $E10_DELAYS; do
  echo "$D" > /sys/module/wireguard/parameters/wg_decrypt_delay_ns
  for C in off both; do
    set_cond "$C"
    # E10a — perf window
    start_load $((PERF_DUR + 12)); sleep 5
    perf record -a -F 499 -o "$OUT/perf_d${D}_${C}.data" -- sleep $PERF_DUR >/dev/null 2>&1
    perf report -i "$OUT/perf_d${D}_${C}.data" --stdio --percent-limit 0.001 2>/dev/null \
      | grep -E 'wg_packet_rx_poll|napi_complete_done|__napi_schedule|net_rx_action|wg_packet_decrypt_worker|chacha|poly1305' \
      > "$OUT/perf_d${D}_${C}.txt"
    sleep 8
    # E10b — bpftrace window
    start_load $((BPF_DUR + 12)); sleep 5
    timeout $((BPF_DUR + 15)) bpftrace /tmp/e10b.bt > "$OUT/bpf_d${D}_${C}.txt" 2>/dev/null
    sleep 8
    echo "E10 delay=$D cond=$C done" >&2
  done
done

set_cond off
for D in $E11_DELAYS; do
  echo "$D" > /sys/module/wireguard/parameters/wg_decrypt_delay_ns
  start_load $((BPF_DUR + 12)); sleep 5
  timeout $((BPF_DUR + 15)) bpftrace /tmp/e11.bt > "$OUT/stall_d${D}_off.txt" 2>/dev/null
  sleep 8
  echo "E11 delay=$D done" >&2
done

echo 0 > /sys/module/wireguard/parameters/wg_decrypt_delay_ns
echo "ARTIFACT_DIR $OUT"
