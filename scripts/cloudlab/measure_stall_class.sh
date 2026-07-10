#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# E11-C — CLASSIFIED stall episodes (the gate for the steering idea).
# The bpftrace E11 probe could not tell a real UNCRYPTED-head stall from an
# empty-queue inter-burst gap. The module now classifies every episode at the
# source (wg_diag_stall_empty / wg_diag_stall_uncrypt arrays:
# n,total_ns,max_ns,le16us,le128us,le1ms,gt1ms). This script runs the Phase B
# capped load at several decrypt delays, baseline condition, and reads the
# per-class accounting over a clean window.
# Decision rule (agreed): UNCRYPT-class typical excess (mean - decrypt floor)
# in 5-20us => steering is future work only; 100+us and growing => go design.
#   nohup sudo bash ~/measure_stall_class.sh 8 > ~/stallclass_run.log 2>&1 &
set -uo pipefail
exec 9>/tmp/stallclass.lock
flock -n 9 || { echo "FATAL: another measure_stall_class.sh is running" >&2; exit 1; }
N=${1:-8}
DELAYS=${2:-"0 5000 10000"}
DUR=${3:-30}
REPS=${4:-3}
GEN=${5:-gen}; NIC=${6:-$(ip -br addr | awk '/192\.168\.1\.1\//{print $1; exit}')}
[ -n "$NIC" ] || { echo "FATAL: cannot find the experiment NIC (192.168.1.1)" >&2; exit 1; }
# NB: the NIC name flips between instantiations (f0 vs f1) — never hardcode it.
LOAD=${LOAD:-2}; STREAMS=${STREAMS:-4}
KO="$HOME/wireguard_trigger.ko"
TS=$(date +%Y%m%d_%H%M); CSV="$HOME/stallclass_$TS.csv"
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
[ -f $P/wg_diag_stall_uncrypt ] || { echo "FATAL: module has no stall classifier (old build?)" >&2; exit 1; }
ethtool -N "$NIC" rx-flow-hash udp4 sdfn >/dev/null 2>&1
bash "$HOME/setup_dut_peers.sh" "$N" >/dev/null
pkill -f 'iperf3 -s' 2>/dev/null; sleep 1
for i in $(seq 0 $((N-1))); do iperf3 -s -p $((5201+i)) -D; done

# capped bulk on all peers via the subsat-style generator (peer 0 included: no
# latency probe here, the module does the measuring)
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
tot=0.0
for f in glob.glob('/tmp/bulk_*.json'):
    try: tot+=json.load(open(f))['end']['sum_received']['bits_per_second']
    except Exception: pass
print("ACTUAL_GBPS %.4f"%(tot/1e9))
PY
EOF
PERT=$(( (LOAD*1000) / (N-1) ))
ssh -n -o StrictHostKeyChecking=no "$GEN" "bash /tmp/genload_bulk.sh $N 8 $PERT $STREAMS" >/dev/null 2>&1 || true  # warm-up

echo 1 > $P/wg_diag
echo "date,srcversion,delay_ns,rep,class,episodes,total_ns,max_ns,le16us,le128us,le1ms,gt1ms,mean_us,load_actual_gbps" > "$CSV"

for D in $DELAYS; do
  echo "$D" > $P/wg_decrypt_delay_ns
  for R in $(seq 1 "$REPS"); do
    ssh -n -o StrictHostKeyChecking=no "$GEN" "bash /tmp/genload_bulk.sh $N $((DUR+12)) $PERT $STREAMS" >/tmp/bulk_out.$$ 2>/dev/null &
    BPID=$!; sleep 6                       # let the load ramp before the window
    echo 0,0,0,0,0,0,0 > $P/wg_diag_stall_empty
    echo 0,0,0,0,0,0,0 > $P/wg_diag_stall_uncrypt
    sleep "$DUR"                           # the measurement window
    EMPTY=$(cat $P/wg_diag_stall_empty); UNC=$(cat $P/wg_diag_stall_uncrypt)
    wait $BPID 2>/dev/null
    ACT=$(awk '/ACTUAL_GBPS/{print $2}' /tmp/bulk_out.$$ 2>/dev/null)
    for row in "empty:$EMPTY" "uncrypt:$UNC"; do
      CLS=${row%%:*}; V=${row#*:}
      IFS=, read -r n tot mx b16 b128 b1m bgt <<< "$V"
      MEAN=$(awk -v t="$tot" -v n="$n" 'BEGIN{printf "%.1f", (n>0? t/n/1000 : 0)}')
      echo "$(date -Is),$SRC,$D,$R,$CLS,$n,$tot,$mx,$b16,$b128,$b1m,$bgt,$MEAN,${ACT:-NA}" >> "$CSV"
      printf "delay=%-6s rep=%s %-8s n=%-8s mean=%-8sus max=%-6sus  <=16us:%-7s 16-128us:%-7s 128us-1ms:%-7s >1ms:%s\n" \
        "$D" "$R" "$CLS" "$n" "$MEAN" "$((mx/1000))" "$b16" "$b128" "$b1m" "$bgt" >&2
    done
  done
done
echo 0 > $P/wg_decrypt_delay_ns; echo 0 > $P/wg_diag
ethtool -N "$NIC" rx-flow-hash udp4 sd >/dev/null 2>&1
pkill -f 'iperf3 -s' 2>/dev/null
echo "ARTIFACT $CSV"
