#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# CONSOLIDATED A/B for the report. One binary (~/wireguard_trigger.ko), four conditions
# toggled at runtime, back-to-back under identical load so they are directly comparable:
#   stock   : all levers off
#   move    : wg_supp=1        (patch moved to the poll-completion site)
#   batch   : wg_trig_k=8      (active wait / coalescing, tau=5us)
#   root    : wg_headwake=1    (wake only when the head is ready)
# Per (cond,rep) captures throughput (genload_json) + wasted-poll fraction (bpftrace).
# The gen load is wrapped in `timeout` so a head-gated stall can't hang the run (it
# records GBPS=NA/0 instead). Also takes ONE per-core CPU snapshot under stock load.
#   sudo bash ~/measure_all.sh 8 5
# Writes ~/all_<ts>.csv (cond,peers,rep,gbps,wasted,useful,wasted_frac) and
#        ~/cpu_<ts>.txt (per-core busy%/softirq% under stock).
set -uo pipefail
N=${1:-8}; REPS=${2:-5}; DUR=${3:-15}; STREAMS=${4:-4}; GEN=${5:-gen}
KO="$HOME/wireguard_trigger.ko"
TS=$(date +%Y%m%d_%H%M); CSV="$HOME/all_$TS.csv"; CPU="$HOME/cpu_$TS.txt"
GUARD=$((DUR+15)); DURP=$((DUR+3))

set_cond() { # $1 = cond name -> set the three knobs
  local s=0 k=0 h=0
  case "$1" in
    stock) ;; move) s=1 ;; batch) k=8 ;; root) h=1 ;;
  esac
  echo $s > /sys/module/wireguard/parameters/wg_supp
  echo $k > /sys/module/wireguard/parameters/wg_trig_k
  echo $h > /sys/module/wireguard/parameters/wg_headwake
}

ip link del wg0 2>/dev/null || true; rmmod wireguard 2>/dev/null || true
insmod "$KO"
echo 5000 > /sys/module/wireguard/parameters/wg_trig_tau_ns
bash "$HOME/setup_dut_peers.sh" "$N" >/dev/null
pkill -f 'iperf3 -s' 2>/dev/null; sleep 1
for i in $(seq 0 $((N-1))); do iperf3 -s -p $((5201+i)) -D; done

echo "cond,peers,rep,gbps,wasted,useful,wasted_frac" > "$CSV"
for rep in $(seq 1 "$REPS"); do
  for cond in $(echo "stock move batch root" | tr ' ' '\n' | sort -R); do
    set_cond "$cond"
    echo "[all] N=$N rep=$rep/$REPS cond=$cond" >&2
    GF=$(mktemp)
    timeout "$GUARD" ssh -o StrictHostKeyChecking=no "$GEN" \
        "bash /tmp/genload_json.sh $N $DUR $STREAMS" > "$GF" 2>/dev/null &
    LOAD=$!
    OUT=$(bpftrace -e '
      kretprobe:wg_packet_rx_poll /retval==0/ { @w += 1; }
      kretprobe:wg_packet_rx_poll /retval>0/  { @u += 1; }
      interval:s:'"$DURP"' { printf("WU %lld %lld\n", @w, @u); exit(); }' 2>/dev/null)
    wait "$LOAD" 2>/dev/null
    W=$(echo "$OUT"|awk '/^WU/{print $2}'); U=$(echo "$OUT"|awk '/^WU/{print $3}')
    G=$(awk '/^GBPS/{print $2}' "$GF"); rm -f "$GF"
    : "${W:=0}" "${U:=0}" "${G:=NA}"
    F=$(awk "BEGIN{ if ($W+$U>0) printf \"%.4f\", $W/($W+$U); else print \"NA\" }")
    echo "CSV,$cond,$N,$rep,$G,$W,$U,$F"
    echo "$cond,$N,$rep,$G,$W,$U,$F" >> "$CSV"
  done
done
pkill -f 'iperf3 -s' 2>/dev/null

# per-core CPU snapshot under stock load (shows the single saturated core)
echo "[all] per-core CPU snapshot (stock)" >&2
set_cond stock
pkill -f 'iperf3 -s' 2>/dev/null; sleep 1
for i in $(seq 0 $((N-1))); do iperf3 -s -p $((5201+i)) -D; done
timeout "$GUARD" ssh -o StrictHostKeyChecking=no "$GEN" "bash /tmp/genload_json.sh $N $DUR $STREAMS" >/dev/null 2>&1 &
sleep 3
python3 - "$DUR" > "$CPU" <<'PY'
import time, sys
win = max(5, int(sys.argv[1]) - 6)
def snap():
    c = {}
    for l in open('/proc/stat'):
        if l.startswith('cpu') and l[3:4].isdigit():
            p = l.split(); t = sum(map(int,p[1:])); idle = int(p[4])+int(p[5]); soft = int(p[7])
            c[p[0]] = (t, idle, soft)
    return c
a = snap(); time.sleep(win); b = snap()
rows = []
for k in a:
    dt = b[k][0]-a[k][0]
    if dt>0: rows.append((k, 100*(1-(b[k][1]-a[k][1])/dt), 100*(b[k][2]-a[k][2])/dt))
rows.sort(key=lambda x:-x[1])
print("core,busy_pct,softirq_pct")
for k,busy,soft in rows:
    print(f"{k},{busy:.1f},{soft:.1f}")
PY
wait 2>/dev/null
pkill -f 'iperf3 -s' 2>/dev/null
echo "[all] done -> $CSV ; $CPU" >&2
echo "ARTIFACTS $CSV $CPU"
