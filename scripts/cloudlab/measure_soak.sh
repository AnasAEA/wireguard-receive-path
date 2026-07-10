#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# Phase C — headwake reliability SOAK (the gate before recommending `both`).
# The producer gate carries a theoretical lost-wakeup risk (a wake skipped on a
# stale head => a TCP flow deadlocks). The Dekker publish-then-recheck is meant
# to close it; this soak is the empirical check: sustained load with the
# two-sided fix ON, two stages (moderate capped, then uncapped near line rate),
# sampling every 15 s: throughput via wg0 rx_bytes, handshake count, and any
# new kernel log lines matching stall/RCU/hung/BUG/WARN.
# PASS = no matching dmesg lines, handshakes stay at N, and per-stage
# throughput never drops below half the stage median (a collapse would be the
# deadlock signature).
#   nohup sudo bash ~/measure_soak.sh 8 > ~/soak_run.log 2>&1 &
set -uo pipefail
exec 9>/tmp/soak.lock
flock -n 9 || { echo "FATAL: another measure_soak.sh is running" >&2; exit 1; }
N=${1:-8}
STAGE_DUR=${2:-900}                 # seconds per stage (default 2x15 min)
GEN=${3:-gen}; NIC=${4:-$(ip -br addr | awk '/192\.168\.1\.1\//{print $1; exit}')}
[ -n "$NIC" ] || { echo "FATAL: cannot find the experiment NIC (192.168.1.1)" >&2; exit 1; }
# NB: the NIC name flips between instantiations (f0 vs f1) — never hardcode it.
LOAD_MOD=${LOAD_MOD:-4}             # stage 1: moderate capped Gb/s
KO="$HOME/wireguard_trigger.ko"
TS=$(date +%Y%m%d_%H%M); CSV="$HOME/soak_$TS.csv"
P=/sys/module/wireguard/parameters

cleanup(){ local p
  for p in wg_supp wg_headwake wg_trig_k wg_decrypt_delay_ns wg_diag; do
    echo 0 > $P/$p 2>/dev/null || true; done
  ethtool -N "$NIC" rx-flow-hash udp4 sd >/dev/null 2>&1 || true
  pkill -f 'iperf3 -s' 2>/dev/null || true; }
trap cleanup EXIT; trap 'cleanup; exit 130' INT; trap 'cleanup; exit 143' TERM

ip link del wg0 2>/dev/null||true; rmmod wireguard 2>/dev/null||true
insmod "$KO"
SRC=$(cat $P/../srcversion 2>/dev/null || echo NA)
ethtool -N "$NIC" rx-flow-hash udp4 sdfn >/dev/null 2>&1
bash "$HOME/setup_dut_peers.sh" "$N" >/dev/null
pkill -f 'iperf3 -s' 2>/dev/null; sleep 1
for i in $(seq 0 $((N-1))); do iperf3 -s -p $((5201+i)) -D; done
echo 1 > $P/wg_supp; echo 1 > $P/wg_headwake     # the two-sided fix, ON for the whole soak

# establish all N handshakes BEFORE measuring — the module reload above reset
# them, and the 2026-07-10 run counted 7/8 through stage 1 only because the
# unloaded peer 0 had never handshaked (harness artifact, not a lost peer)
ssh -n -o StrictHostKeyChecking=no "$GEN" \
  "for i in \$(seq 0 $((N-1))); do ip netns exec ns_c\$i ping -c1 -W2 10.0.0.1 >/dev/null 2>&1 & done; wait" || true
sleep 2

DMESG_BASE=$(dmesg | wc -l)
echo "stage,t_s,gbps,handshakes,new_dmesg" > "$CSV"

run_stage(){ # $1=stage name  $2=gen command
  local stage=$1 cmd=$2 t=0 b0 b1 gbps hs dm fails=0
  ssh -n -o StrictHostKeyChecking=no "$GEN" "$cmd" >/dev/null 2>&1 &
  local LPID=$!
  sleep 10
  while [ $t -lt "$STAGE_DUR" ]; do
    b0=$(cat /sys/class/net/wg0/statistics/rx_bytes); sleep 15
    b1=$(cat /sys/class/net/wg0/statistics/rx_bytes); t=$((t+15))
    gbps=$(awk -v d=$((b1-b0)) 'BEGIN{printf "%.2f", d*8/15/1e9}')
    hs=$(wg show wg0 2>/dev/null | grep -c "latest handshake")
    dm=$(dmesg | tail -n +$((DMESG_BASE+1)) | grep -ciE "rcu|stall|hung|soft lockup|BUG|WARNING" || true)
    echo "$stage,$t,$gbps,$hs,$dm" >> "$CSV"
    printf "%-9s t=%-5ss gbps=%-6s handshakes=%s/%s dmesg_hits=%s\n" "$stage" "$t" "$gbps" "$hs" "$N" "$dm" >&2
    [ "$dm" -gt 0 ] && fails=1
  done
  kill $LPID 2>/dev/null; wait $LPID 2>/dev/null
  ssh -n -o StrictHostKeyChecking=no "$GEN" "pkill iperf3" 2>/dev/null || true
  return $fails
}

PERT=$(( (LOAD_MOD*1000) / (N-1) ))
run_stage moderate "for i in \$(seq 1 $((N-1))); do ip netns exec ns_c\$i iperf3 -c 10.0.0.1 -p \$((5201+i)) -t $((STAGE_DUR+30)) -P 4 -b $((PERT/4))M >/dev/null 2>&1 & done; wait" || true
run_stage linerate "for i in \$(seq 0 $((N-1))); do ip netns exec ns_c\$i iperf3 -c 10.0.0.1 -p \$((5201+i)) -t $((STAGE_DUR+30)) -P 4 >/dev/null 2>&1 & done; wait" || true

# verdict
python3 - "$CSV" "$N" <<'PY'
import csv, statistics as st, sys
rows = list(csv.DictReader(open(sys.argv[1]))); n = int(sys.argv[2])
ok = True
for stage in ("moderate", "linerate"):
    g = [float(r["gbps"]) for r in rows if r["stage"] == stage]
    hs = [int(r["handshakes"]) for r in rows if r["stage"] == stage]
    dm = [int(r["new_dmesg"]) for r in rows if r["stage"] == stage]
    med = st.median(g) if g else 0
    # the first minute of each stage is TCP ramp — judge only steady state
    collapse = any(x < med / 2 for x in g[4:])
    hs_bad = len(hs) > 4 and min(hs[4:]) < n
    print(f"{stage}: median {med:.2f} Gb/s, steady-state min {min(g[4:] or g):.2f}, "
          f"handshakes steady min {min(hs[4:] or hs)}/{n}, dmesg hits {max(dm)}")
    if collapse or hs_bad or max(dm) > 0: ok = False
print("VERDICT:", "PASS - no stall, no collapse, handshakes held" if ok else "FAIL - inspect the log")
PY
echo "ARTIFACT $CSV  (srcversion $SRC)"
