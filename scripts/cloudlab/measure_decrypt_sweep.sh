#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# Phase B — DECRYPT-COST SENSITIVITY (CLOUDLAB_PLAN_phase2.md Phase B; Alain 2026-06-25).
# c220g2 Xeons decrypt fast (T_decrypt ~5-6us), so the head clears quickly and the EoI fix
# is a clean null at sub-saturation (Phase A). Hypothesis: with slower decrypt the head
# stays UNCRYPTED longer => more wasted re-polls => the fix removes more work and may become
# user-visible. We inject a per-decrypt busy-wait (wg_decrypt_delay_ns, poll cost untouched)
# and sweep it, off vs both, mapping the fix's payoff vs the decrypt:poll cost ratio.
#
# REWRITTEN 2026-07-02 — the old version produced the collapsed 2026-06-26 sweep. Fixes:
#  - CAPPED sub-line-rate bulk load (iperf3 -b on peers 1..N-1, measure_subsat.sh design)
#    instead of uncapped genload, so slowing decrypt doesn't implode the pipeline; default
#    target 2 Gb/s total to stay below the decrypt bottleneck across the whole sweep.
#  - ONE measurement window per run: latency (sockperf, dedicated peer 0) + CPU CE +
#    verified actual throughput + wasted polls counted together — not two disjoint windows.
#  - Full CSV row per run: p50/p99/p999, softirq/system/total CE, polls/wasted/frac,
#    retransmits, wg0 rx_dropped delta.
#  - Pipeline collapse is DATA here (it locates the knee): a run whose actual load deviates
#    > REJECT_DEV from target gets status=collapse and the row is KEPT (the safe+transition
#    region is the evidence; collapse marks the boundary).
# Caveat: the bpftrace kretprobe on wg_packet_rx_poll runs DURING the latency window
# (Phase A deliberately had no probe). Its overhead is identical across conditions and
# delays => the off-vs-both A/B stays fair, but do NOT compare absolute latency values
# against Phase A's unprobed numbers.
#
#   sudo bash ~/measure_decrypt_sweep.sh 8                          # delays 0/1/2/5/10 us
#   sudo bash ~/measure_decrypt_sweep.sh 8 "0 2000 5000 10000 20000" 30
#   LOAD=2 REPS=5 CONDS="off both" sudo bash ~/measure_decrypt_sweep.sh 8
# Runtime: delays x conds x reps x ~(DUR+10)s — defaults 5x2x5x~40s ~ 35 min.
set -uo pipefail
N=${1:-8}
DELAYS=${2:-"0 1000 2000 5000 10000"}   # wg_decrypt_delay_ns values (ns)
DUR=${3:-30}
GEN=${4:-gen}
NIC=${5:-enp6s0f0}
LOAD=${LOAD:-2}                   # target TOTAL bulk Gb/s over peers 1..N-1 (sub-knee cap)
CONDS=${CONDS:-"off both"}        # subset of: off supp root both
REPS=${REPS:-5}
STREAMS=${STREAMS:-4}             # TCP streams per bulk tunnel
REJECT_DEV=${REJECT_DEV:-0.40}    # |actual-target|/target beyond this => status=collapse
KO="$HOME/wireguard_trigger.ko"
TS=$(date +%Y%m%d_%H%M); CSV="$HOME/decsweep_$TS.csv"; PLACE="$HOME/decsweep_$TS.placement.txt"
HOST=$(hostname -s); HZ=$(getconf CLK_TCK); LPORT=11111
SRC=NA   # set after insmod below, so it reflects the module actually under test

cleanup(){ local p
  for p in wg_supp wg_headwake wg_trig_k wg_decrypt_delay_ns; do
    echo 0 > /sys/module/wireguard/parameters/$p 2>/dev/null || true; done
  ethtool -N "$NIC" rx-flow-hash udp4 sd >/dev/null 2>&1 || true
  pkill -f 'iperf3 -s' 2>/dev/null || true; pkill sockperf 2>/dev/null || true
  pkill bpftrace 2>/dev/null || true; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

set_cond(){ local s=0 h=0; case "$1" in supp|move) s=1;; root) h=1;; both) s=1; h=1;; esac
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
SRC=$(cat /sys/module/wireguard/srcversion 2>/dev/null || echo NA)
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

PERT=$(( (LOAD*1000) / (N-1) ))
# warm-up burst so the first randomized run isn't measured cold (handshakes, cwnd, C-states)
ssh -n -o StrictHostKeyChecking=no "$GEN" "bash /tmp/genload_bulk.sh $N 8 $PERT $STREAMS" >/dev/null 2>&1 || true

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
GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo NA)

echo "date,srcversion,host,delay_ns,condition,peers,load_target_gbps,load_actual_gbps,latency_tool,lat_samples,p50_us,p99_us,p999_us,softirq_ce,system_ce,total_busy_ce,polls,wasted,wasted_frac,retransmits,drops,status,notes" > "$CSV"

# randomize (delay,cond,rep) to decorrelate drift
ORDER=$(for D in $DELAYS; do for C in $CONDS; do for r in $(seq 1 $REPS); do echo "$D $C $r"; done; done; done | shuf)
while read -r DLY COND REP; do
  echo "$DLY" > /sys/module/wireguard/parameters/wg_decrypt_delay_ns
  set_cond "$COND"
  ssh -n -o StrictHostKeyChecking=no "$GEN" "bash /tmp/genload_bulk.sh $N $((DUR+6)) $PERT $STREAMS" >/tmp/bulk_out.$$ 2>/dev/null &
  BPID=$!; sleep 2
  DROP0=$(cat /sys/class/net/wg0/statistics/rx_dropped 2>/dev/null || echo 0)
  timeout $((DUR+15)) bpftrace -e '
    kretprobe:wg_packet_rx_poll { @polls++; if (retval==0) { @wasted++; } }
    interval:s:'"$DUR"' { printf("R %llu %llu\n", @polls, @wasted); exit(); }' \
    >/tmp/bt_out.$$ 2>/dev/null &
  BTPID=$!; sleep 1
  read B0 S0 SI0 < <(cpu_snap); T0=$(date +%s.%N)
  LAT=$(ssh -n -o StrictHostKeyChecking=no "$GEN" \
        "sudo ip netns exec ns_c0 sockperf ping-pong -i 10.0.0.1 -p $LPORT --tcp -t $DUR --mps=max 2>/dev/null" \
        | sed -r 's/\x1b\[[0-9;]*m//g')
  T1=$(date +%s.%N); read B1 S1 SI1 < <(cpu_snap)
  DROP1=$(cat /sys/class/net/wg0/statistics/rx_dropped 2>/dev/null || echo 0)
  wait $BTPID 2>/dev/null
  read POLLS WASTED < <(awk '/^R /{print $2, $3}' /tmp/bt_out.$$ 2>/dev/null)
  wait $BPID 2>/dev/null; read ACT RTX < <(awk '/ACTUAL_GBPS/{print $2, $4}' /tmp/bulk_out.$$ 2>/dev/null)
  WALL=$(awk -v a=$T0 -v b=$T1 'BEGIN{print (b-a>0? b-a : 1)}')
  SOFT_CE=$(awk -v d=$((S1-S0))  -v w=$WALL -v h=$HZ 'BEGIN{printf "%.3f", d/(w*h)}')
  SYS_CE=$(awk  -v d=$((SI1-SI0)) -v w=$WALL -v h=$HZ 'BEGIN{printf "%.3f", d/(w*h)}')
  BUSY_CE=$(awk -v d=$((B1-B0))  -v w=$WALL -v h=$HZ 'BEGIN{printf "%.3f", d/(w*h)}')
  P50=$(echo  "$LAT" | awk '/percentile 50.000/{print $NF}')
  P99=$(echo  "$LAT" | awk '/percentile 99.000/{print $NF}')
  P999=$(echo "$LAT" | awk '/percentile 99.900/{print $NF}')
  NOBS=$(echo "$LAT" | awk '/observations/{for(i=1;i<=NF;i++) if($i=="Total") print $(i+1)}')
  WF=$(awk -v w="${WASTED:-0}" -v p="${POLLS:-0}" 'BEGIN{printf "%.4f", (p>0? w/p:0)}')
  DROPS=$((DROP1-DROP0))
  DEV=$(awk -v a=${ACT:-0} -v t=$LOAD 'BEGIN{d=(a-t)/t; if(d<0)d=-d; printf "%.3f", d}')
  STATUS=ok; awk -v d=$DEV -v thr=$REJECT_DEV 'BEGIN{exit !(d>thr)}' && STATUS=collapse
  echo "$(date -Is),$SRC,$HOST,$DLY,$COND,$N,$LOAD,${ACT:-0},sockperf,${NOBS:-0},${P50:-NA},${P99:-NA},${P999:-NA},$SOFT_CE,$SYS_CE,$BUSY_CE,${POLLS:-0},${WASTED:-0},$WF,${RTX:-0},$DROPS,$STATUS,src=$SRC;gov=$GOV;load_dev=$DEV" >> "$CSV"
  printf "delay=%-6s cond=%-4s rep=%s | wasted=%s%% | p50=%s p99=%s us | soft=%s busy=%s CE | act=%sG %s\n" \
    "$DLY" "$COND" "$REP" "$(awk -v f=$WF 'BEGIN{printf "%.1f", f*100}')" \
    "${P50:-NA}" "${P99:-NA}" "$SOFT_CE" "$BUSY_CE" "${ACT:-0}" \
    "$([ "$STATUS" = collapse ] && echo '[COLLAPSE]')" >&2
done <<< "$ORDER"

echo 0 > /sys/module/wireguard/parameters/wg_decrypt_delay_ns
ethtool -N "$NIC" rx-flow-hash udp4 sd >/dev/null 2>&1
pkill -f 'iperf3 -s' 2>/dev/null; pkill sockperf 2>/dev/null
echo "ARTIFACT $CSV"
echo "PLACEMENT $PLACE"
