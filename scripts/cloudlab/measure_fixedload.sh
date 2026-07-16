#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# Phase D confirmation, gate B — matched-load CPU + same-tunnel tail latency.
# The sweep's efficiency number (Gb/s per busy CE) is a ratio of two moving
# measurements; the cleaner claim is "same delivered bytes, less CPU". So:
# single tunnel, bulk CAPPED at LOAD Gb/s (default 3.8 — below the ~4.2 off
# ceiling, so every condition can hold the same load), plus a low-rate
# sockperf UDP ping-pong over the SAME tunnel (ns_c1 -> 10.0.0.1: same outer
# 5-tuple, same RX queue, same NAPI context as the bulk — the regime where the
# E11-C head-blocking actually lives; the old dedicated probe peer never
# shared it, which is why its p99 was null by construction).
# Paired blocks (off / both / steal4 / bsteal4), order re-shuffled per block;
# analysis on within-block deltas (analyze_confirm.py). Declared primary:
# steal4-off on total_busy_ce at matched load. Secondary: bsteal4-steal4
# (composition) and the p99/p99.9 probe deltas — the latency question is
# EXPLORATORY: no positive claim unless it separates cleanly.
# WGDIAG=1 (default) captures the E11-C classifier + steal counters, same
# methodology as measure_steal.sh. The classifier is only comparable between
# conditions that leave wg_supp off (off, steal4): suppression biases episode
# observation under both/bsteal4.
# Sidecar $CSV.percore: per-core busy CE for every run (block cond core ce).
#   nohup sudo bash ~/measure_fixedload.sh > ~/fixedload_run.log 2>&1 &
set -uo pipefail
exec 9>/tmp/fixedload.lock
flock -n 9 || { echo "FATAL: another measure_fixedload.sh is running" >&2; exit 1; }
BLOCKS=${1:-8}
DUR=${2:-60}
GEN=${3:-gen}
NIC=${4:-$(ip -br addr | awk '/192\.168\.1\.1\//{print $1; exit}')}
[ -n "$NIC" ] || { echo "FATAL: cannot find the experiment NIC (192.168.1.1)" >&2; exit 1; }
LOAD=${LOAD:-3.8}            # Gb/s: total bulk cap over the single tunnel
STREAMS=${STREAMS:-4}
MPS=${MPS:-2000}             # probe msgs/s: 2000 x 60 s = 120k samples, p99.9 rests on ~120 obs
WGDIAG=${WGDIAG:-1}
CONDS="off both steal4 bsteal4"
KO="$HOME/wireguard_trigger.ko"
TS=$(date +%Y%m%d_%H%M); CSV="$HOME/fixedload_$TS.csv"; PCF="$CSV.percore"
P=/sys/module/wireguard/parameters
HZ=$(getconf CLK_TCK); LPORT=11111
PSM=$(awk -v l="$LOAD" -v s="$STREAMS" 'BEGIN{printf "%d", l*1000/s}')   # Mbit/s per stream

cleanup(){ local p
  for p in wg_supp wg_headwake wg_trig_k wg_decrypt_delay_ns wg_diag wg_steal; do
    echo 0 > $P/$p 2>/dev/null || true; done
  ethtool -N "$NIC" rx-flow-hash udp4 sd >/dev/null 2>&1 || true
  pkill -f 'iperf3 -s' 2>/dev/null || true; pkill sockperf 2>/dev/null || true; }
trap cleanup EXIT; trap 'cleanup; exit 130' INT; trap 'cleanup; exit 143' TERM

set_cond(){ local s=0 h=0 st=0
  case "$1" in both) s=1; h=1;; steal4) st=4;; bsteal4) s=1; h=1; st=4;; esac
  echo $s  > $P/wg_supp; echo 0 > $P/wg_trig_k
  echo $h  > $P/wg_headwake
  echo $st > $P/wg_steal; }

cpu_snap(){ awk '/^cpu[0-9]/{u=$2;n=$3;s=$4;id=$5;io=$6;irq=$7;sq=$8;st=$9;
  tot+=u+n+s+id+io+irq+sq+st; idle+=id+io; soft+=sq; sysirq+=s+irq+sq}
  END{printf "%d %d %d", tot-idle, soft, sysirq}' /proc/stat; }
percore_snap(){ awk '/^cpu[0-9]/{print $1, $2+$3+$4+$7+$8+$9}' /proc/stat; }

ip link del wg0 2>/dev/null||true; rmmod wireguard 2>/dev/null||true
insmod "$KO"
SRC=$(cat $P/../srcversion 2>/dev/null || echo NA)
[ -f $P/wg_steal ] || { echo "FATAL: module has no wg_steal (old build?)" >&2; exit 1; }
ethtool -N "$NIC" rx-flow-hash udp4 sdfn >/dev/null 2>&1   # irrelevant for 1 tunnel, kept for parity
bash "$HOME/setup_dut_peers.sh" 8 >/dev/null
pkill -f 'iperf3 -s' 2>/dev/null; pkill sockperf 2>/dev/null; sleep 1
for i in $(seq 0 7); do iperf3 -s -p $((5201+i)) -D; done
( sockperf server -i 10.0.0.1 -p $LPORT >/dev/null 2>&1 & ); sleep 1     # UDP server
ssh -n -o StrictHostKeyChecking=no "$GEN" \
  "for i in \$(seq 0 7); do ip netns exec ns_c\$i ping -c1 -W2 10.0.0.1 >/dev/null 2>&1 & done; wait" || true
[ "$WGDIAG" = "1" ] && echo 1 > $P/wg_diag

echo "date,srcversion,block,cond,load_gbps,retransmits,lat_n,p50_us,p90_us,p99_us,p999_us,max_us,softirq_ce,system_ce,total_busy_ce,handshakes,unc_n,unc_total_ns,steal_pulled,steal_unblocked,steal_dryruns,dmesg_delta" > "$CSV"
: > "$PCF"
DMESG_BASE=$(dmesg | wc -l)

for BLK in $(seq 1 "$BLOCKS"); do
  ssh -n -o StrictHostKeyChecking=no "$GEN" \
    "ip netns exec ns_c1 iperf3 -c 10.0.0.1 -p 5202 -P $STREAMS -b ${PSM}M -t 6 >/dev/null 2>&1" || true  # per-block warm-up
  for COND in $(shuf -e $CONDS); do
    set_cond "$COND"
    ssh -n -o StrictHostKeyChecking=no "$GEN" \
      "ip netns exec ns_c1 iperf3 -c 10.0.0.1 -p 5202 -P $STREAMS -b ${PSM}M -t $((DUR+10)) -J 2>/dev/null" \
      >/tmp/bulk_out.$$ 2>/dev/null &
    BPID=$!; sleep 5                            # let the capped bulk ramp before the window
    if [ "$WGDIAG" = "1" ]; then
      echo 0,0,0,0,0,0,0 > $P/wg_diag_stall_uncrypt
      for c in wg_diag_steal_pulled wg_diag_steal_unblocked wg_diag_steal_dryruns; do echo 0 > $P/$c; done
    fi
    PC0=$(percore_snap); read B0 S0 SI0 < <(cpu_snap); T0=$(date +%s.%N)
    LAT=$(ssh -n -o StrictHostKeyChecking=no "$GEN" \
          "sudo ip netns exec ns_c1 sockperf ping-pong -i 10.0.0.1 -p $LPORT -t $DUR --mps=$MPS 2>/dev/null" \
          | sed -r 's/\x1b\[[0-9;]*m//g')
    T1=$(date +%s.%N); read B1 S1 SI1 < <(cpu_snap); PC1=$(percore_snap)
    if [ "$WGDIAG" = "1" ]; then
      IFS=, read -r UN UT _ <<< "$(cat $P/wg_diag_stall_uncrypt)"
      SP=$(cat $P/wg_diag_steal_pulled); SU=$(cat $P/wg_diag_steal_unblocked); SD=$(cat $P/wg_diag_steal_dryruns)
    else UN=NA; UT=NA; SP=NA; SU=NA; SD=NA; fi
    wait $BPID 2>/dev/null
    read GBPS RTX < <(python3 -c "import json,sys
d=json.load(open('/tmp/bulk_out.$$'))['end']
print('%.4f %d'%(d['sum_received']['bits_per_second']/1e9, d['sum_sent'].get('retransmits',0)))" 2>/dev/null || echo "NA NA")
    P50=$(echo  "$LAT" | awk '/percentile 50.000/{print $NF}')
    P90=$(echo  "$LAT" | awk '/percentile 90.000/{print $NF}')
    P99=$(echo  "$LAT" | awk '/percentile 99.000/{print $NF}')
    P999=$(echo "$LAT" | awk '/percentile 99.900/{print $NF}')
    PMAX=$(echo "$LAT" | awk '/<MAX> observation/{print $NF}')
    NOBS=$(echo "$LAT" | awk '/observations/{for(i=1;i<=NF;i++) if($i=="Total") print $(i+1)}')
    HS=$(wg show wg0 latest-handshakes | awk '$2>0{c++} END{print c+0}')
    WALL=$(awk -v a=$T0 -v b=$T1 'BEGIN{print (b-a>0? b-a : 1)}')
    SOFT_CE=$(awk -v d=$((S1-S0))  -v w=$WALL -v h=$HZ 'BEGIN{printf "%.3f", d/(w*h)}')
    SYS_CE=$(awk  -v d=$((SI1-SI0)) -v w=$WALL -v h=$HZ 'BEGIN{printf "%.3f", d/(w*h)}')
    BUSY_CE=$(awk -v d=$((B1-B0))  -v w=$WALL -v h=$HZ 'BEGIN{printf "%.3f", d/(w*h)}')
    DM=$(dmesg | tail -n +$((DMESG_BASE+1)) | grep -ciE "rcu|stall|hung|soft lockup|BUG|WARNING" || true)
    echo "$(date -Is),$SRC,$BLK,$COND,${GBPS:-NA},${RTX:-NA},${NOBS:-0},${P50:-NA},${P90:-NA},${P99:-NA},${P999:-NA},${PMAX:-NA},$SOFT_CE,$SYS_CE,$BUSY_CE,$HS,$UN,$UT,$SP,$SU,$SD,$DM" >> "$CSV"
    paste <(printf '%s\n' "$PC0") <(printf '%s\n' "$PC1") | \
      awk -v w=$WALL -v h=$HZ -v b=$BLK -v c=$COND '{printf "%s %s %s %.3f\n", b, c, $1, ($4-$2)/(w*h)}' >> "$PCF"
    printf "blk=%-2s cond=%-7s | load=%sG rtx=%-5s | p50=%-7s p99=%-7s p999=%-8s | soft=%s busy=%s | dmesg=%s\n" \
      "$BLK" "$COND" "${GBPS:-NA}" "${RTX:-NA}" "${P50:-NA}" "${P99:-NA}" "${P999:-NA}" "$SOFT_CE" "$BUSY_CE" "$DM" >&2
    rm -f /tmp/bulk_out.$$
    sleep 3
  done
done

pkill -f 'iperf3 -s' 2>/dev/null; pkill sockperf 2>/dev/null
echo "ARTIFACT $CSV  (srcversion $SRC, blocks=$BLOCKS, load=${LOAD}G, mps=$MPS, wg_diag=$WGDIAG)"
echo "ARTIFACT $PCF  (per-core busy CE per run)"
