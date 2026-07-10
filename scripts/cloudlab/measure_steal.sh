#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# Phase D — does the work-stealing poll (wg_steal) convert its mechanism win
# (-67% head-blocked wall time, smoke 2026-07-10) into something a user sees?
# Four conditions isolate the contributions:
#   off    = baseline            both   = two-sided wake fix
#   steal  = wg_steal=8 alone    bsteal = both + wg_steal=8 (the full stack)
# Per run, ONE window measuring together: sockperf latency on dedicated peer 0,
# capped bulk on peers 1..N-1, CPU CE (3 lenses), verified actual load,
# retransmits — plus the E11-C classifier arrays (module-side, no bpftrace) and
# the steal counters. Unlike the wake-side fixes, stealing DELIVERS EARLIER, so
# p99 is allowed to move; CPU should stay ~neutral (decrypt work migrates from
# workers to softirq — watch softirq_ce rise while total stays flat).
#   nohup sudo bash ~/measure_steal.sh 8 > ~/steal_run.log 2>&1 &
set -uo pipefail
exec 9>/tmp/steal.lock
flock -n 9 || { echo "FATAL: another measure_steal.sh is running" >&2; exit 1; }
N=${1:-8}
DUR=${2:-30}
REPS=${3:-4}
GEN=${4:-gen}
NIC=${5:-$(ip -br addr | awk '/192\.168\.1\.1\//{print $1; exit}')}
[ -n "$NIC" ] || { echo "FATAL: cannot find the experiment NIC (192.168.1.1)" >&2; exit 1; }
CONDS=${CONDS:-"off both steal bsteal"}
LOAD=${LOAD:-2}; STREAMS=${STREAMS:-4}
KO="$HOME/wireguard_trigger.ko"
TS=$(date +%Y%m%d_%H%M); CSV="$HOME/steal_$TS.csv"
P=/sys/module/wireguard/parameters
HZ=$(getconf CLK_TCK); LPORT=11111

cleanup(){ local p
  for p in wg_supp wg_headwake wg_trig_k wg_decrypt_delay_ns wg_diag wg_steal; do
    echo 0 > $P/$p 2>/dev/null || true; done
  ethtool -N "$NIC" rx-flow-hash udp4 sd >/dev/null 2>&1 || true
  pkill -f 'iperf3 -s' 2>/dev/null || true; pkill sockperf 2>/dev/null || true; }
trap cleanup EXIT; trap 'cleanup; exit 130' INT; trap 'cleanup; exit 143' TERM

set_cond(){ local s=0 h=0 st=0
  case "$1" in both) s=1; h=1;; steal) st=8;; bsteal) s=1; h=1; st=8;; esac
  echo $s  > $P/wg_supp; echo 0 > $P/wg_trig_k
  echo $h  > $P/wg_headwake
  echo $st > $P/wg_steal; }

cpu_snap(){ awk '/^cpu[0-9]/{u=$2;n=$3;s=$4;id=$5;io=$6;irq=$7;sq=$8;st=$9;
  tot+=u+n+s+id+io+irq+sq+st; idle+=id+io; soft+=sq; sysirq+=s+irq+sq}
  END{printf "%d %d %d", tot-idle, soft, sysirq}' /proc/stat; }

ip link del wg0 2>/dev/null||true; rmmod wireguard 2>/dev/null||true
insmod "$KO"
SRC=$(cat $P/../srcversion 2>/dev/null || echo NA)
[ -f $P/wg_steal ] || { echo "FATAL: module has no wg_steal (old build?)" >&2; exit 1; }
ethtool -N "$NIC" rx-flow-hash udp4 sdfn >/dev/null 2>&1
bash "$HOME/setup_dut_peers.sh" "$N" >/dev/null
pkill -f 'iperf3 -s' 2>/dev/null; pkill sockperf 2>/dev/null; sleep 1
for i in $(seq 0 $((N-1))); do iperf3 -s -p $((5201+i)) -D; done
( sockperf server -i 10.0.0.1 -p $LPORT --tcp >/dev/null 2>&1 & ); sleep 1

ssh -o StrictHostKeyChecking=no "$GEN" "cat > /tmp/genload_bulk.sh" <<'EOF'
#!/bin/bash
N=$1; DUR=$2; PERT=$3; STREAMS=${4:-4}
PS=$(( PERT / STREAMS )); [ "$PS" -lt 1 ] && PS=1
rm -f /tmp/bulk_*.json
for i in $(seq 1 $((N-1))); do
  ip netns exec "ns_c$i" iperf3 -c 10.0.0.1 -p $((5201+i)) -t "$DUR" -P "$STREAMS" -b "${PS}M" -J >/tmp/bulk_$i.json 2>/dev/null &
done
wait
python3 - <<'PY'
import json,glob
tot=0.0; rtx=0
for f in glob.glob('/tmp/bulk_*.json'):
    try:
        d=json.load(open(f)); tot+=d['end']['sum_received']['bits_per_second']
        rtx+=d['end']['sum_sent'].get('retransmits',0)
    except Exception: pass
print("ACTUAL_GBPS %.4f RETRANS %d"%(tot/1e9, rtx))
PY
EOF
PERT=$(( (LOAD*1000) / (N-1) ))
ssh -n -o StrictHostKeyChecking=no "$GEN" \
  "for i in \$(seq 0 $((N-1))); do ip netns exec ns_c\$i ping -c1 -W2 10.0.0.1 >/dev/null 2>&1 & done; wait" || true
ssh -n -o StrictHostKeyChecking=no "$GEN" "bash /tmp/genload_bulk.sh $N 8 $PERT $STREAMS" >/dev/null 2>&1 || true

echo 1 > $P/wg_diag
echo "date,srcversion,cond,rep,load_actual_gbps,lat_samples,p50_us,p99_us,p999_us,softirq_ce,system_ce,total_busy_ce,unc_n,unc_total_ns,unc_mean_us,unc_gt128us,steal_pulled,steal_unblocked,steal_dryruns,retransmits" > "$CSV"

ORDER=$(for C in $CONDS; do for r in $(seq 1 "$REPS"); do echo "$C $r"; done; done | shuf)
while read -r COND REP; do
  set_cond "$COND"
  ssh -n -o StrictHostKeyChecking=no "$GEN" "bash /tmp/genload_bulk.sh $N $((DUR+8)) $PERT $STREAMS" >/tmp/bulk_out.$$ 2>/dev/null &
  BPID=$!; sleep 4
  echo 0,0,0,0,0,0,0 > $P/wg_diag_stall_uncrypt
  for c in wg_diag_steal_pulled wg_diag_steal_unblocked wg_diag_steal_dryruns; do echo 0 > $P/$c; done
  read B0 S0 SI0 < <(cpu_snap); T0=$(date +%s.%N)
  LAT=$(ssh -n -o StrictHostKeyChecking=no "$GEN" \
        "sudo ip netns exec ns_c0 sockperf ping-pong -i 10.0.0.1 -p $LPORT --tcp -t $DUR --mps=max 2>/dev/null" \
        | sed -r 's/\x1b\[[0-9;]*m//g')
  T1=$(date +%s.%N); read B1 S1 SI1 < <(cpu_snap)
  UNC=$(cat $P/wg_diag_stall_uncrypt)
  SP=$(cat $P/wg_diag_steal_pulled); SU=$(cat $P/wg_diag_steal_unblocked); SD=$(cat $P/wg_diag_steal_dryruns)
  wait $BPID 2>/dev/null; read ACT RTX < <(awk '/ACTUAL_GBPS/{print $2, $4}' /tmp/bulk_out.$$ 2>/dev/null)
  WALL=$(awk -v a=$T0 -v b=$T1 'BEGIN{print (b-a>0? b-a : 1)}')
  SOFT_CE=$(awk -v d=$((S1-S0))  -v w=$WALL -v h=$HZ 'BEGIN{printf "%.3f", d/(w*h)}')
  SYS_CE=$(awk  -v d=$((SI1-SI0)) -v w=$WALL -v h=$HZ 'BEGIN{printf "%.3f", d/(w*h)}')
  BUSY_CE=$(awk -v d=$((B1-B0))  -v w=$WALL -v h=$HZ 'BEGIN{printf "%.3f", d/(w*h)}')
  P50=$(echo  "$LAT" | awk '/percentile 50.000/{print $NF}')
  P99=$(echo  "$LAT" | awk '/percentile 99.000/{print $NF}')
  P999=$(echo "$LAT" | awk '/percentile 99.900/{print $NF}')
  NOBS=$(echo "$LAT" | awk '/observations/{for(i=1;i<=NF;i++) if($i=="Total") print $(i+1)}')
  IFS=, read -r un ut umax b16 b128 b1m bgt <<< "$UNC"
  UMEAN=$(awk -v t="$ut" -v n="$un" 'BEGIN{printf "%.1f", (n>0? t/n/1000 : 0)}')
  UGT=$((b1m + bgt))
  echo "$(date -Is),$SRC,$COND,$REP,${ACT:-NA},${NOBS:-0},${P50:-NA},${P99:-NA},${P999:-NA},$SOFT_CE,$SYS_CE,$BUSY_CE,$un,$ut,$UMEAN,$UGT,$SP,$SU,$SD,${RTX:-0}" >> "$CSV"
  printf "cond=%-7s rep=%s | p50=%-8s p99=%-8s | soft=%-6s busy=%-6s | unc_n=%-7s mean=%-7sus | pulled=%-7s | act=%sG\n" \
    "$COND" "$REP" "${P50:-NA}" "${P99:-NA}" "$SOFT_CE" "$BUSY_CE" "$un" "$UMEAN" "$SP" "${ACT:-NA}" >&2
done <<< "$ORDER"

echo 0 > $P/wg_diag
ethtool -N "$NIC" rx-flow-hash udp4 sd >/dev/null 2>&1
pkill -f 'iperf3 -s' 2>/dev/null; pkill sockperf 2>/dev/null
echo "ARTIFACT $CSV  (srcversion $SRC)"
