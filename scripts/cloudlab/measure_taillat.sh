#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# SUPERSEDED by measure_subsat.sh — this prototype runs the ping latency on ns_c0 WHILE that
# same tunnel also carries bulk load, so the latency self-interferes. measure_subsat.sh fixes
# this (peer 0 = latency only, bulk on peers 1..N-1) and adds CPU + sockperf p99.9. Kept for ref.
# TAIL LATENCY at a NON-SATURATED operating point (Alain 2026-06-25). Under saturation
# latency is queue-dominated (~1.6 ms) and the µs-scale fix is invisible. Here we hold a
# FIXED sub-line-rate offered load (so the cores have headroom) on the sdfn spread, and ask
# whether removing wasted polls shows up in the TAIL (p99/p999) — where a saved ~1µs of
# softirq work on the receive core can delay a real packet. off vs both (two-sided fix).
#   sudo bash ~/measure_taillat.sh 8           # 8 peers, 2 Gb/s total offered
#   sudo bash ~/measure_taillat.sh 32 3000     # 32 peers, 3 Gb/s total offered
# TOTAL_MBIT is split across the N tunnels, so the offered load stays fixed as N grows.
# Writes ~/taillat_<ts>.csv : cond,rtt_ms (one row per ping). Prints p50/p90/p99/p999.
set -uo pipefail
N=${1:-8}; TOTAL_MBIT=${2:-2000}; DUR=${3:-20}; GEN=${4:-gen}; NIC=${5:-enp6s0f0}
PINGS=${6:-2000}; PINT=${7:-0.005}
CONDS=${CONDS:-"off both"}
KO="$HOME/wireguard_trigger.ko"; TS=$(date +%Y%m%d_%H%M); CSV="$HOME/taillat_$TS.csv"
GUARD=$((DUR+20)); PERT=$(( TOTAL_MBIT / N )); [ "$PERT" -lt 1 ] && PERT=1

cleanup(){ local p
  for p in wg_supp wg_headwake wg_trig_k wg_decrypt_delay_ns; do
    echo 0 > /sys/module/wireguard/parameters/$p 2>/dev/null || true; done
  ethtool -N "$NIC" rx-flow-hash udp4 sd >/dev/null 2>&1 || true
  pkill -f 'iperf3 -s' 2>/dev/null || true; }
trap cleanup EXIT INT TERM

set_cond() { local s=0 h=0; case "$1" in move) s=1 ;; root) h=1 ;; both) s=1; h=1 ;; esac
  echo $s > /sys/module/wireguard/parameters/wg_supp
  echo 0  > /sys/module/wireguard/parameters/wg_trig_k
  echo $h > /sys/module/wireguard/parameters/wg_headwake; }

# capped, paced background load on gen (TCP -b => sub-saturation offered rate)
ssh -o StrictHostKeyChecking=no "$GEN" "cat > /tmp/genload_cap.sh" <<'EOF'
#!/bin/bash
N=$1; DUR=$2; PERT=$3
for i in $(seq 0 $((N-1))); do
  ip netns exec "ns_c$i" iperf3 -c 10.0.0.1 -p $((5201+i)) -t "$DUR" -b "${PERT}M" >/dev/null 2>&1 &
done
wait
EOF

ip link del wg0 2>/dev/null || true; rmmod wireguard 2>/dev/null || true
insmod "$KO"
ethtool -N "$NIC" rx-flow-hash udp4 sdfn >/dev/null 2>&1
bash "$HOME/setup_dut_peers.sh" "$N" >/dev/null
pkill -f 'iperf3 -s' 2>/dev/null; sleep 1
for i in $(seq 0 $((N-1))); do iperf3 -s -p $((5201+i)) -D; done
echo "cond,rtt_ms" > "$CSV"
echo "[taillat] N=$N offered=${TOTAL_MBIT}Mbit (${PERT}M/tunnel) sdfn  conds: $CONDS" >&2

for cond in $CONDS; do
  set_cond "$cond"
  timeout "$GUARD" ssh -o StrictHostKeyChecking=no "$GEN" "bash /tmp/genload_cap.sh $N $DUR $PERT" >/dev/null 2>&1 &
  LOAD=$!
  sleep 3
  RTTS=$(timeout $((PINGS/100 + 15)) ssh -o StrictHostKeyChecking=no "$GEN" \
      "sudo ip netns exec ns_c0 ping -c $PINGS -i $PINT -W 1 10.0.0.1 2>/dev/null" \
      | grep -oE 'time=[0-9.]+' | sed 's/time=//')
  if [ -n "$RTTS" ]; then
    echo "$RTTS" | while read -r r; do echo "$cond,$r" >> "$CSV"; done
    echo "[taillat] cond=$cond : $(echo "$RTTS" | wc -l) samples" >&2
  else echo "$cond,NA" >> "$CSV"; echo "[taillat] cond=$cond : NO RTT (stall?)" >&2; fi
  wait "$LOAD" 2>/dev/null
done
ethtool -N "$NIC" rx-flow-hash udp4 sd >/dev/null 2>&1
pkill -f 'iperf3 -s' 2>/dev/null
echo "ARTIFACT $CSV"

python3 - "$CSV" "$CONDS" <<'PY'
import sys, csv, statistics as st
from collections import defaultdict
d = defaultdict(list)
for r in csv.DictReader(open(sys.argv[1])):
    try: d[r["cond"]].append(float(r["rtt_ms"]))
    except: pass
def pct(xs,p): xs=sorted(xs); return xs[min(len(xs)-1,int(p/100*len(xs)))]
print(f"\n{'cond':6}{'n':>6}{'p50':>9}{'p90':>9}{'p99':>9}{'p99.9':>9}{'max':>9}")
for c in sys.argv[2].split():
    xs=d.get(c,[])
    if xs: print(f"{c:6}{len(xs):>6}{st.median(xs):>9.3f}{pct(xs,90):>9.3f}{pct(xs,99):>9.3f}{pct(xs,99.9):>9.3f}{max(xs):>9.3f}")
    else:  print(f"{c:6}{'--- no samples ---':>30}")
PY
