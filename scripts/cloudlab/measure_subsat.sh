#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# Phase A — sub-saturation latency + CPU for the two-sided EoI fix. Methodology in
# docs/cloudlab/CLOUDLAB_PLAN_phase2.md. The point: at line rate the fix can't help
# (throughput-bound); with headroom, a saved ~1us poll on the receive core may show in tail
# latency and/or CPU. We hold a FIXED capped bulk load on peers 1..N-1 (sdfn spread), reserve
# peer 0 for a request/response latency probe (sockperf ping-pong, no bulk on it), and measure
# latency + CPU together, off vs both (and the single-side controls).
#
#   sudo bash ~/measure_subsat.sh 8 "0 2 4 6"            # default conds off+both, 6 reps, 30s
#   CONDS="off supp root both" REPS=8 sudo bash ~/measure_subsat.sh 8 "0 4"
#
# One CSV row per run (schema below); a sidecar .placement.txt records IRQ/affinity/governor.
# Latency tool = sockperf (reports p50/p99/p99.9 natively, unlike netperf omni which tops at p99).
set -uo pipefail
N=${1:-8}
LOADS=${2:-"0 2 4 6"}             # target TOTAL bulk Gb/s, split over peers 1..N-1
CONDS=${CONDS:-"off both"}        # subset of: off supp root both
REPS=${REPS:-6}
DUR=${DUR:-30}
GEN=${GEN:-gen}
NIC=${NIC:-enp6s0f0}
STREAMS=${STREAMS:-4}             # TCP streams per bulk tunnel (to actually reach the target rate)
REJECT_DEV=${REJECT_DEV:-0.40}    # flag a run only if |actual-target|/target exceeds this (catch
                                  # COLLAPSES, not iperf3 -b pacing slop). targets are NOMINAL;
                                  # analysis bins by load_actual_gbps. off vs both at one target
                                  # see the same generation => same actual => valid comparison.
KO="$HOME/wireguard_trigger.ko"
TS=$(date +%Y%m%d_%H%M); CSV="$HOME/subsat_$TS.csv"; PLACE="$HOME/subsat_$TS.placement.txt"
SRC=$(cat /sys/module/wireguard/srcversion 2>/dev/null || echo NA)
HOST=$(hostname -s); HZ=$(getconf CLK_TCK); LPORT=11111

set_cond(){ local s=0 h=0; case "$1" in supp) s=1;; root) h=1;; both) s=1; h=1;; esac
  echo $s >/sys/module/wireguard/parameters/wg_supp
  echo 0  >/sys/module/wireguard/parameters/wg_trig_k
  echo $h >/sys/module/wireguard/parameters/wg_headwake; }

# sum, across all cores, of (busy, softirq, system+irq+softirq) jiffies -> CE later
cpu_snap(){ awk '/^cpu[0-9]/{u=$2;n=$3;s=$4;id=$5;io=$6;irq=$7;sq=$8;st=$9;
  tot+=u+n+s+id+io+irq+sq+st; idle+=id+io; soft+=sq; sysirq+=s+irq+sq}
  END{printf "%d %d %d", tot-idle, soft, sysirq}' /proc/stat; }

# --- one-time setup ---
ip link del wg0 2>/dev/null||true; rmmod wireguard 2>/dev/null||true
insmod "$KO"
ethtool -N "$NIC" rx-flow-hash udp4 sdfn >/dev/null 2>&1
bash "$HOME/setup_dut_peers.sh" "$N" >/dev/null
pkill -f 'iperf3 -s' 2>/dev/null; pkill sockperf 2>/dev/null; sleep 1
for i in $(seq 0 $((N-1))); do iperf3 -s -p $((5201+i)) -D; done
( sockperf server -i 10.0.0.1 -p $LPORT --tcp >/dev/null 2>&1 & ); sleep 1

# bulk load on gen: peers 1..N-1 only (peer 0 reserved for latency), capped TCP, JSON out
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

# --- placement recorded once (the first result was about flow/core placement) ---
{ echo "host=$HOST srcversion=$SRC date=$(date -Is) kernel=$(uname -r)"
  echo "--- rx-flow-hash udp4 ---"; ethtool -n "$NIC" rx-flow-hash udp4 2>/dev/null
  echo "--- ethtool -l ---"; ethtool -l "$NIC" 2>/dev/null
  echo "--- NIC IRQ smp_affinity_list ---"
  for irq in $(grep "$NIC" /proc/interrupts | awk -F: '{print $1}'); do
    echo "irq$irq -> $(cat /proc/irq/$(echo $irq|tr -d ' ')/smp_affinity_list 2>/dev/null)"; done
  echo "--- governor ---"; cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo NA
  echo "--- numa ---"; lscpu | grep -iE "NUMA|Socket|Model name"
} > "$PLACE" 2>/dev/null
NICIRQ=$(grep -c "$NIC" /proc/interrupts)
GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo NA)

echo "date,commit,host,condition,peers,load_target_gbps,load_actual_gbps,latency_tool,lat_samples,p50_us,p99_us,p999_us,softirq_ce,system_ce,total_busy_ce,wasted_poll_pct,fresh_wake_pct,retransmits,drops,nic_irq_count,sdfn_state,notes" > "$CSV"

# randomize (load,cond,rep) to decorrelate drift
ORDER=$(for L in $LOADS; do for C in $CONDS; do for r in $(seq 1 $REPS); do echo "$L $C $r"; done; done; done | shuf)
while read -r LOAD COND REP; do
  set_cond "$COND"
  ACT="0.0000"; RTX=0
  PERT=0; [ "$LOAD" != 0 ] && PERT=$(( (LOAD*1000) / (N-1) ))
  if [ "$LOAD" != 0 ]; then
    ssh -n -o StrictHostKeyChecking=no "$GEN" "bash /tmp/genload_bulk.sh $N $((DUR+6)) $PERT $STREAMS" >/tmp/bulk_out.$$ 2>/dev/null &
    BPID=$!; sleep 2
  fi
  read B0 S0 SI0 < <(cpu_snap); T0=$(date +%s.%N)
  LAT=$(ssh -n -o StrictHostKeyChecking=no "$GEN" \
        "sudo ip netns exec ns_c0 sockperf ping-pong -i 10.0.0.1 -p $LPORT --tcp -t $DUR --mps=max 2>/dev/null" \
        | sed -r 's/\x1b\[[0-9;]*m//g')
  T1=$(date +%s.%N); read B1 S1 SI1 < <(cpu_snap)
  if [ "$LOAD" != 0 ]; then wait $BPID 2>/dev/null; read ACT RTX < <(awk '/ACTUAL_GBPS/{print $2, $4}' /tmp/bulk_out.$$ 2>/dev/null); fi
  WALL=$(awk -v a=$T0 -v b=$T1 'BEGIN{print (b-a>0? b-a : 1)}')
  SOFT_CE=$(awk -v d=$((S1-S0))  -v w=$WALL -v h=$HZ 'BEGIN{printf "%.3f", d/(w*h)}')
  SYS_CE=$(awk  -v d=$((SI1-SI0)) -v w=$WALL -v h=$HZ 'BEGIN{printf "%.3f", d/(w*h)}')
  BUSY_CE=$(awk -v d=$((B1-B0))  -v w=$WALL -v h=$HZ 'BEGIN{printf "%.3f", d/(w*h)}')
  P50=$(echo  "$LAT" | awk '/percentile 50.000/{print $NF}')
  P99=$(echo  "$LAT" | awk '/percentile 99.000/{print $NF}')
  P999=$(echo "$LAT" | awk '/percentile 99.900/{print $NF}')
  NOBS=$(echo "$LAT" | awk '/observations/{for(i=1;i<=NF;i++) if($i=="Total") print $(i+1)}')
  NOTE="src=$SRC;gov=$GOV"
  if [ "$LOAD" != 0 ]; then
    DEV=$(awk -v a=${ACT:-0} -v t=$LOAD 'BEGIN{d=(a-t)/t; if(d<0)d=-d; printf "%.3f", d}')
    awk -v d=$DEV -v thr=$REJECT_DEV 'BEGIN{exit !(d>thr)}' && NOTE="$NOTE;REJECT_load_dev=$DEV"
  fi
  echo "$(date -Is),$SRC,$HOST,$COND,$N,$LOAD,${ACT:-0},sockperf,${NOBS:-0},${P50:-NA},${P99:-NA},${P999:-NA},$SOFT_CE,$SYS_CE,$BUSY_CE,NA,NA,${RTX:-0},NA,$NICIRQ,sdfn,$NOTE" >> "$CSV"
  printf "load=%sG cond=%-4s rep=%s | p50=%s p99=%s p999=%s us | soft=%s sys=%s busy=%s CE | act=%sG %s\n" \
    "$LOAD" "$COND" "$REP" "${P50:-NA}" "${P99:-NA}" "${P999:-NA}" "$SOFT_CE" "$SYS_CE" "$BUSY_CE" "${ACT:-0}" \
    "$([ "${NOTE##*REJECT}" != "$NOTE" ] && echo '[REJECT]')" >&2
done <<< "$ORDER"

ethtool -N "$NIC" rx-flow-hash udp4 sd >/dev/null 2>&1
pkill -f 'iperf3 -s' 2>/dev/null; pkill sockperf 2>/dev/null
echo "ARTIFACT $CSV"
echo "PLACEMENT $PLACE"
echo "NOTE: wasted_poll_pct/fresh_wake_pct are NA here (bpftrace would perturb the latency window);"
echo "      they are cross-referenced from measure_missed.sh (flat ~27%->~14% across 8-64 peers)."
