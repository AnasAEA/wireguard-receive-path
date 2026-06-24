#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# LATENCY under load, per condition. While the 8 tunnels saturate the receive core
# (iperf load), we ping dut THROUGH the tunnel from ns_c0 and record each RTT. The wake
# policy changes WHEN packets are delivered, so this is where wg_supp / wg_trig / headwake
# could matter even though throughput doesn't. One binary, knobs toggled at runtime.
#   sudo bash ~/measure_latency.sh 8 14
# Writes ~/lat_<ts>.csv : cond,rtt_ms  (one row per ping sample). NA-guarded for stalls.
set -uo pipefail
N=${1:-8}; DUR=${2:-14}; STREAMS=${3:-4}; GEN=${4:-gen}
PINGS=${5:-500}; PINT=${6:-0.01}
KO="$HOME/wireguard_trigger.ko"
TS=$(date +%Y%m%d_%H%M); CSV="$HOME/lat_$TS.csv"
GUARD=$((DUR+15))

set_cond() {
  local s=0 k=0 h=0
  case "$1" in move) s=1 ;; batch) k=8 ;; root) h=1 ;; esac
  echo $s > /sys/module/wireguard/parameters/wg_supp
  echo $k > /sys/module/wireguard/parameters/wg_trig_k
  echo $h > /sys/module/wireguard/parameters/wg_headwake
}

ip link del wg0 2>/dev/null || true; rmmod wireguard 2>/dev/null || true
insmod "$KO"; echo 5000 > /sys/module/wireguard/parameters/wg_trig_tau_ns
bash "$HOME/setup_dut_peers.sh" "$N" >/dev/null
pkill -f 'iperf3 -s' 2>/dev/null; sleep 1
for i in $(seq 0 $((N-1))); do iperf3 -s -p $((5201+i)) -D; done

echo "cond,rtt_ms" > "$CSV"
for cond in stock move batch root; do
  set_cond "$cond"
  echo "[lat] cond=$cond : load + ping x$PINGS" >&2
  # background load on all N tunnels
  timeout "$GUARD" ssh -o StrictHostKeyChecking=no "$GEN" \
      "bash /tmp/genload_json.sh $N $DUR $STREAMS" >/dev/null 2>&1 &
  LOAD=$!
  sleep 3   # let the load ramp and saturate the core
  # ping THROUGH the tunnel from ns_c0 (itself under load), capture each RTT
  RTTS=$(timeout $((PINGS/50 + 12)) ssh -o StrictHostKeyChecking=no "$GEN" \
      "sudo ip netns exec ns_c0 ping -c $PINGS -i $PINT -W 1 10.0.0.1 2>/dev/null" \
      | grep -oE 'time=[0-9.]+' | sed 's/time=//')
  if [ -n "$RTTS" ]; then
    echo "$RTTS" | while read -r r; do echo "$cond,$r" >> "$CSV"; done
    NS=$(echo "$RTTS" | wc -l)
    echo "[lat] cond=$cond : $NS samples" >&2
  else
    echo "$cond,NA" >> "$CSV"; echo "[lat] cond=$cond : NO RTT (stall?)" >&2
  fi
  wait "$LOAD" 2>/dev/null
done
pkill -f 'iperf3 -s' 2>/dev/null
echo "[lat] done -> $CSV" >&2
echo "ARTIFACT $CSV"

# quick summary on dut
python3 - "$CSV" <<'PY'
import sys, csv, statistics as st
from collections import defaultdict
d = defaultdict(list)
for r in csv.DictReader(open(sys.argv[1])):
    try: d[r["cond"]].append(float(r["rtt_ms"]))
    except: pass
def pct(xs,p): xs=sorted(xs); return xs[min(len(xs)-1,int(p/100*len(xs)))]
print(f"\n{'cond':8}{'n':>5}{'med_ms':>9}{'p90':>8}{'p99':>8}{'max':>8}")
for c in ("stock","move","batch","root"):
    xs=d.get(c,[])
    if xs: print(f"{c:8}{len(xs):>5}{st.median(xs):>9.3f}{pct(xs,90):>8.3f}{pct(xs,99):>8.3f}{max(xs):>8.3f}")
    else:  print(f"{c:8}{'--- no samples ---':>30}")
PY
