#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# CPU-per-byte A/B in the SPREAD regime (Design B). With the NIC hash on ports (sdfn) the
# receive work is on ~8 cores at ~55% and throughput is ~line rate (9 Gb/s). There the fix
# can't add throughput, so the right metric is EFFICIENCY: how much CPU does each variant
# burn for the same bytes? We sum per-core busy across the WHOLE machine (= cores-equiv
# used) and divide by throughput. A fix that lowers cores-equiv at equal Gb/s is a real win
# (more peers per box). One binary, knobs toggled at runtime.
#   sudo bash ~/measure_cpubyte.sh 8 4
# Writes ~/cpb_<ts>.csv : cond,rep,gbps,cores_equiv,cpu_per_gbps,wasted_frac
set -uo pipefail
N=${1:-8}; REPS=${2:-4}; DUR=${3:-15}; STREAMS=${4:-4}; GEN=${5:-gen}; NIC=${6:-enp6s0f0}
KO="$HOME/wireguard_trigger.ko"; TS=$(date +%Y%m%d_%H%M); CSV="$HOME/cpb_$TS.csv"
GUARD=$((DUR+15)); DURP=$((DUR+3))

set_cond() { local s=0 k=0 h=0
  case "$1" in move) s=1 ;; batch) k=8 ;; root) h=1 ;; esac
  echo $s >/sys/module/wireguard/parameters/wg_supp
  echo $k >/sys/module/wireguard/parameters/wg_trig_k
  echo $h >/sys/module/wireguard/parameters/wg_headwake; }

ip link del wg0 2>/dev/null||true; rmmod wireguard 2>/dev/null||true
insmod "$KO"; echo 5000 >/sys/module/wireguard/parameters/wg_trig_tau_ns
ethtool -N "$NIC" rx-flow-hash udp4 sdfn >/dev/null 2>&1   # SPREAD across cores
echo "[cpb] rx-flow-hash udp4 = $(ethtool -n "$NIC" rx-flow-hash udp4 | grep -c .)" >&2
bash "$HOME/setup_dut_peers.sh" "$N" >/dev/null
pkill -f 'iperf3 -s' 2>/dev/null; sleep 1
for i in $(seq 0 $((N-1))); do iperf3 -s -p $((5201+i)) -D; done

echo "cond,rep,gbps,cores_equiv,cpu_per_gbps,wasted_frac" > "$CSV"
for rep in $(seq 1 "$REPS"); do
  for cond in $(echo "stock move batch root" | tr ' ' '\n' | sort -R); do
    set_cond "$cond"
    echo "[cpb] rep=$rep/$REPS cond=$cond" >&2
    GF=$(mktemp)
    timeout "$GUARD" ssh -o StrictHostKeyChecking=no "$GEN" \
        "bash /tmp/genload_json.sh $N $DUR $STREAMS" >"$GF" 2>/dev/null &
    LOAD=$!
    sleep 3
    # sum of per-core busy fractions over a window = cores-equivalent used
    CE=$(python3 - "$DUR" <<'PY'
import time, sys
win=max(5,int(sys.argv[1])-7)
def snap():
    c={}
    for l in open('/proc/stat'):
        if l.startswith('cpu') and l[3:4].isdigit():
            p=l.split(); t=sum(map(int,p[1:])); idle=int(p[4])+int(p[5])
            c[p[0]]=(t,idle)
    return c
a=snap(); time.sleep(win); b=snap()
ce=0.0
for k in a:
    dt=b[k][0]-a[k][0]
    if dt>0: ce+=1-(b[k][1]-a[k][1])/dt
print(f"{ce:.2f}")
PY
)
    # wasted-poll fraction across all cores
    OUT=$(bpftrace -e '
      kretprobe:wg_packet_rx_poll /retval==0/ { @w+=1; }
      kretprobe:wg_packet_rx_poll /retval>0/  { @u+=1; }
      interval:s:'"$DURP"' { printf("WU %lld %lld\n",@w,@u); exit(); }' 2>/dev/null)
    wait "$LOAD" 2>/dev/null
    W=$(echo "$OUT"|awk '/^WU/{print $2}'); U=$(echo "$OUT"|awk '/^WU/{print $3}')
    G=$(awk '/^GBPS/{print $2}' "$GF"); rm -f "$GF"
    : "${W:=0}" "${U:=0}" "${G:=NA}" "${CE:=0}"
    WF=$(awk "BEGIN{if($W+$U>0)printf\"%.4f\",$W/($W+$U);else print\"NA\"}")
    CPB=$(awk "BEGIN{if(\"$G\"!=\"NA\" && $G>0)printf\"%.3f\",$CE/$G;else print\"NA\"}")
    echo "CSV,$cond,$rep,$G,$CE,$CPB,$WF"
    echo "$cond,$rep,$G,$CE,$CPB,$WF" >> "$CSV"
  done
done
ethtool -N "$NIC" rx-flow-hash udp4 sd >/dev/null 2>&1   # revert to default
pkill -f 'iperf3 -s' 2>/dev/null
echo "[cpb] hash reverted to sd. done -> $CSV" >&2

python3 - "$CSV" <<'PY'
import sys,csv,statistics as st
from collections import defaultdict
g=defaultdict(lambda:defaultdict(list))
for r in csv.DictReader(open(sys.argv[1])):
    for m in("gbps","cores_equiv","cpu_per_gbps","wasted_frac"):
        try: g[r["cond"]][m].append(float(r[m]))
        except: pass
print(f"\n{'cond':8}{'n':>3}{'gbps':>8}{'cores_eq':>10}{'cpu/Gbps':>10}{'wasted%':>9}")
for c in("stock","move","batch","root"):
    if not g[c]["gbps"]: continue
    print(f"{c:8}{len(g[c]['gbps']):>3}{st.median(g[c]['gbps']):>8.2f}"
          f"{st.median(g[c]['cores_equiv']):>10.2f}{st.median(g[c]['cpu_per_gbps']):>10.3f}"
          f"{st.median(g[c]['wasted_frac'])*100:>9.1f}")
if g["stock"]["cpu_per_gbps"]:
    base=st.median(g["stock"]["cpu_per_gbps"])
    print(f"\n-- CPU/Gbps vs stock (négatif = plus efficace) --  stock={base:.3f}")
    for c in("move","batch","root"):
        if g[c]["cpu_per_gbps"]:
            d=st.median(g[c]["cpu_per_gbps"])-base
            print(f"  {c:6}: {d:+.3f} ({100*d/base:+.1f}%)")
PY
