#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# CPU-efficiency A/B in the SPREAD regime (sdfn), done RIGHT. The previous cpubyte run was
# swamped by decrypt (kworker) + iperf servers and too noisy. Here we ALSO isolate the
# softirq CPU — where wg_packet_rx_poll and the trigger's timer actually run — which is the
# only thing the fix can move. We report BOTH:
#   soft_ce  = sum over cores of softirq-fraction  (SENSITIVE detector of the fix's effect)
#   tot_ce   = sum over cores of busy-fraction     (the real "peers per box" cost, but noisy)
# Longer window + more reps to beat down variance. One binary, knobs toggled at runtime.
#   sudo bash ~/measure_cpueff.sh 8 8
# CSV: cond,rep,gbps,tot_ce,soft_ce,wasted_frac
set -uo pipefail
N=${1:-8}; REPS=${2:-8}; DUR=${3:-20}; STREAMS=${4:-4}; GEN=${5:-gen}; NIC=${6:-enp6s0f0}
KO="$HOME/wireguard_trigger.ko"; TS=$(date +%Y%m%d_%H%M); CSV="$HOME/cpueff_$TS.csv"
GUARD=$((DUR+15)); DURP=$((DUR+3))

set_cond() { local s=0 k=0 h=0
  case "$1" in move) s=1 ;; batch) k=8 ;; root) h=1 ;; esac
  echo $s >/sys/module/wireguard/parameters/wg_supp
  echo $k >/sys/module/wireguard/parameters/wg_trig_k
  echo $h >/sys/module/wireguard/parameters/wg_headwake; }

ip link del wg0 2>/dev/null||true; rmmod wireguard 2>/dev/null||true
insmod "$KO"; echo 5000 >/sys/module/wireguard/parameters/wg_trig_tau_ns
ethtool -N "$NIC" rx-flow-hash udp4 sdfn >/dev/null 2>&1
bash "$HOME/setup_dut_peers.sh" "$N" >/dev/null
pkill -f 'iperf3 -s' 2>/dev/null; sleep 1
for i in $(seq 0 $((N-1))); do iperf3 -s -p $((5201+i)) -D; done

echo "cond,rep,gbps,tot_ce,soft_ce,wasted_frac" > "$CSV"
for rep in $(seq 1 "$REPS"); do
  for cond in $(echo "stock move batch root" | tr ' ' '\n' | sort -R); do
    set_cond "$cond"
    echo "[eff] rep=$rep/$REPS cond=$cond" >&2
    GF=$(mktemp)
    timeout "$GUARD" ssh -o StrictHostKeyChecking=no "$GEN" \
        "bash /tmp/genload_json.sh $N $DUR $STREAMS" >"$GF" 2>/dev/null &
    LOAD=$!
    sleep 4   # let it settle and saturate the wire
    read TOT SOFT < <(python3 - "$DUR" <<'PY'
import time, sys
win=max(8,int(sys.argv[1])-8)
def snap():
    c={}
    for l in open('/proc/stat'):
        if l.startswith('cpu') and l[3:4].isdigit():
            p=l.split(); t=sum(map(int,p[1:])); idle=int(p[4])+int(p[5]); soft=int(p[7])
            c[p[0]]=(t,idle,soft)
    return c
a=snap(); time.sleep(win); b=snap()
tot=soft=0.0
for k in a:
    dt=b[k][0]-a[k][0]
    if dt>0:
        tot+=1-(b[k][1]-a[k][1])/dt
        soft+=(b[k][2]-a[k][2])/dt
print(f"{tot:.2f} {soft:.2f}")
PY
)
    OUT=$(bpftrace -e '
      kretprobe:wg_packet_rx_poll /retval==0/ { @w+=1; }
      kretprobe:wg_packet_rx_poll /retval>0/  { @u+=1; }
      interval:s:'"$DURP"' { printf("WU %lld %lld\n",@w,@u); exit(); }' 2>/dev/null)
    wait "$LOAD" 2>/dev/null
    W=$(echo "$OUT"|awk '/^WU/{print $2}'); U=$(echo "$OUT"|awk '/^WU/{print $3}')
    G=$(awk '/^GBPS/{print $2}' "$GF"); rm -f "$GF"
    : "${W:=0}" "${U:=0}" "${G:=NA}" "${TOT:=0}" "${SOFT:=0}"
    WF=$(awk "BEGIN{if($W+$U>0)printf\"%.4f\",$W/($W+$U);else print\"NA\"}")
    echo "CSV,$cond,$rep,$G,$TOT,$SOFT,$WF"
    echo "$cond,$rep,$G,$TOT,$SOFT,$WF" >> "$CSV"
  done
done
ethtool -N "$NIC" rx-flow-hash udp4 sd >/dev/null 2>&1
pkill -f 'iperf3 -s' 2>/dev/null
echo "[eff] hash reverted to sd. done -> $CSV" >&2

python3 - "$CSV" <<'PY'
import sys,csv,statistics as st
from collections import defaultdict
g=defaultdict(lambda:defaultdict(list))
for r in csv.DictReader(open(sys.argv[1])):
    for m in("gbps","tot_ce","soft_ce","wasted_frac"):
        try: g[r["cond"]][m].append(float(r[m]))
        except: pass
def med(x): return st.median(x) if x else float("nan")
def iqr(x):
    if len(x)<4: return 0.0
    q=st.quantiles(x,n=4); return q[2]-q[0]
print(f"\n{'cond':7}{'n':>3}{'gbps':>7}{'soft_ce':>9}{'(IQR)':>8}{'tot_ce':>8}{'(IQR)':>8}{'wasted%':>9}")
for c in("stock","move","batch","root"):
    if not g[c]["gbps"]: continue
    print(f"{c:7}{len(g[c]['gbps']):>3}{med(g[c]['gbps']):>7.2f}"
          f"{med(g[c]['soft_ce']):>9.2f}{iqr(g[c]['soft_ce']):>8.2f}"
          f"{med(g[c]['tot_ce']):>8.2f}{iqr(g[c]['tot_ce']):>8.2f}"
          f"{med(g[c]['wasted_frac'])*100:>9.1f}")
b=g["stock"]
if b["soft_ce"]:
    print(f"\n-- vs stock (négatif = moins de CPU pour le même débit) --")
    for c in("move","batch","root"):
        if g[c]["soft_ce"]:
            ds=med(g[c]['soft_ce'])-med(b['soft_ce']); dt=med(g[c]['tot_ce'])-med(b['tot_ce'])
            print(f"  {c:6}: softirq {ds:+.2f} ce ({100*ds/med(b['soft_ce']):+.1f}%)   total {dt:+.2f} ce")
PY
