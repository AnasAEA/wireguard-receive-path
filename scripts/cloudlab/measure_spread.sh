#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# DESIGN B — break the single-core funnel. The NIC hashes UDP flows on IP only, so the 8
# same-IP tunnels collapse onto one RX queue -> one core. Flip the hash to include L4
# ports (sdfn): the tunnels' distinct source ports fan out across the 40 queues -> cores.
# Measures, for each hash, the aggregate throughput AND the per-core CPU (how many cores
# actually do receive softirq). Stock module (no fix) — this is purely about parallelism.
#   sudo bash ~/measure_spread.sh 8
# Writes ~/spread_<ts>.txt (summary) + ~/cpu_sd_<ts>.csv / ~/cpu_sdfn_<ts>.csv (per-core).
set -uo pipefail
N=${1:-8}; DUR=${2:-15}; STREAMS=${3:-4}; GEN=${4:-gen}; NIC=${5:-enp6s0f1}
KO="$HOME/wireguard_trigger.ko"; TS=$(date +%Y%m%d_%H%M)
GUARD=$((DUR+15))

ip link del wg0 2>/dev/null || true; rmmod wireguard 2>/dev/null || true
insmod "$KO"   # all knobs 0 = stock
bash "$HOME/setup_dut_peers.sh" "$N" >/dev/null
pkill -f 'iperf3 -s' 2>/dev/null; sleep 1
for i in $(seq 0 $((N-1))); do iperf3 -s -p $((5201+i)) -D; done

snap_cpu() { # $1 = outfile ; samples per-core busy/softirq over a window during load
  python3 - "$DUR" <<'PY' > "$1"
import time, sys
win = max(5, int(sys.argv[1]) - 6)
def snap():
    c = {}
    for l in open('/proc/stat'):
        if l.startswith('cpu') and l[3:4].isdigit():
            p=l.split(); t=sum(map(int,p[1:])); idle=int(p[4])+int(p[5]); soft=int(p[7])
            c[p[0]]=(t,idle,soft)
    return c
a=snap(); time.sleep(win); b=snap()
print("core,busy_pct,softirq_pct")
rows=[]
for k in a:
    dt=b[k][0]-a[k][0]
    if dt>0: rows.append((k,100*(1-(b[k][1]-a[k][1])/dt),100*(b[k][2]-a[k][2])/dt))
for k,bz,sf in sorted(rows,key=lambda x:-x[1]): print(f"{k},{bz:.1f},{sf:.1f}")
PY
}

SUM="$HOME/spread_$TS.txt"; : > "$SUM"
for HASH in sd sdfn; do
  ethtool -N "$NIC" rx-flow-hash udp4 "$HASH" >/dev/null 2>&1
  echo "================ rx-flow-hash udp4 = $HASH ================" | tee -a "$SUM"
  # two throughput reps
  GS=()
  for rep in 1 2; do
    GF=$(mktemp)
    timeout "$GUARD" ssh -o StrictHostKeyChecking=no "$GEN" "bash /tmp/genload_json.sh $N $DUR $STREAMS" >"$GF" 2>/dev/null
    g=$(awk '/^GBPS/{print $2}' "$GF"); rm -f "$GF"; GS+=("${g:-0}")
    echo "  rep$rep GBPS=${g:-0}" | tee -a "$SUM"
  done
  # one CPU snapshot under load
  CPUF="$HOME/cpu_${HASH}_$TS.csv"
  timeout "$GUARD" ssh -o StrictHostKeyChecking=no "$GEN" "bash /tmp/genload_json.sh $N $DUR $STREAMS" >/dev/null 2>&1 &
  sleep 3; snap_cpu "$CPUF"; wait 2>/dev/null
  HOT=$(awk -F, 'NR>1 && $2>50' "$CPUF" | wc -l)
  TOPS=$(awk -F, 'NR>1 && $2>50{printf "%s(%.0f%%) ",$1,$2}' "$CPUF" | head -c 200)
  echo "  cores >50% busy: $HOT  -> $TOPS" | tee -a "$SUM"
  echo "  per-core file: $CPUF" | tee -a "$SUM"
done
ethtool -N "$NIC" rx-flow-hash udp4 sd >/dev/null 2>&1   # revert to default
pkill -f 'iperf3 -s' 2>/dev/null
echo "[spread] reverted hash to sd (default). summary -> $SUM" >&2
echo "ARTIFACTS $SUM $HOME/cpu_sd_$TS.csv $HOME/cpu_sdfn_$TS.csv"
