#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# Phase D gate 2+3 — the HEADLINE result needs its own auditable artifact.
# Single-tunnel uncapped throughput (one tunnel = one 5-tuple = one RX queue:
# the regime sdfn cannot spread), sweeping wg_steal 0/1/2/4/8/16 with enough
# reps and CPU capture to state the +3-5% as an interval, not an anecdote.
# Per run: gbps (iperf3 sum_received), retransmits, CPU CE x3 around the exact
# window, dmesg delta. Shuffled order, NIC autodetect, flock.
#   nohup sudo bash ~/measure_single.sh > ~/single_run.log 2>&1 &
set -uo pipefail
exec 9>/tmp/single.lock
flock -n 9 || { echo "FATAL: another measure_single.sh is running" >&2; exit 1; }
STEALS=${1:-"0 1 2 4 8 16"}
DUR=${2:-20}
REPS=${3:-5}
GEN=${4:-gen}
NIC=${5:-$(ip -br addr | awk '/192\.168\.1\.1\//{print $1; exit}')}
[ -n "$NIC" ] || { echo "FATAL: cannot find the experiment NIC (192.168.1.1)" >&2; exit 1; }
KO="$HOME/wireguard_trigger.ko"
TS=$(date +%Y%m%d_%H%M); CSV="$HOME/single_$TS.csv"
P=/sys/module/wireguard/parameters
HZ=$(getconf CLK_TCK)

cleanup(){ local p
  for p in wg_supp wg_headwake wg_trig_k wg_decrypt_delay_ns wg_diag wg_steal; do
    echo 0 > $P/$p 2>/dev/null || true; done
  ethtool -N "$NIC" rx-flow-hash udp4 sd >/dev/null 2>&1 || true
  pkill -f 'iperf3 -s' 2>/dev/null || true; }
trap cleanup EXIT; trap 'cleanup; exit 130' INT; trap 'cleanup; exit 143' TERM

cpu_snap(){ awk '/^cpu[0-9]/{u=$2;n=$3;s=$4;id=$5;io=$6;irq=$7;sq=$8;st=$9;
  tot+=u+n+s+id+io+irq+sq+st; idle+=id+io; soft+=sq; sysirq+=s+irq+sq}
  END{printf "%d %d %d", tot-idle, soft, sysirq}' /proc/stat; }

ip link del wg0 2>/dev/null||true; rmmod wireguard 2>/dev/null||true
insmod "$KO"
SRC=$(cat $P/../srcversion 2>/dev/null || echo NA)
[ -f $P/wg_steal ] || { echo "FATAL: module has no wg_steal (old build?)" >&2; exit 1; }
ethtool -N "$NIC" rx-flow-hash udp4 sdfn >/dev/null 2>&1   # irrelevant for 1 tunnel, kept for parity
bash "$HOME/setup_dut_peers.sh" 8 >/dev/null
pkill -f 'iperf3 -s' 2>/dev/null; sleep 1
for i in $(seq 0 7); do iperf3 -s -p $((5201+i)) -D; done
ssh -n -o StrictHostKeyChecking=no "$GEN" \
  "ip netns exec ns_c1 ping -c1 -W2 10.0.0.1 >/dev/null 2>&1" || true
ssh -n -o StrictHostKeyChecking=no "$GEN" \
  "ip netns exec ns_c1 iperf3 -c 10.0.0.1 -p 5202 -P 4 -t 6 >/dev/null 2>&1" || true  # warm-up

echo "date,srcversion,wg_steal,rep,gbps,retransmits,softirq_ce,system_ce,total_busy_ce,dmesg_delta" > "$CSV"
DMESG_BASE=$(dmesg | wc -l)

ORDER=$(for S in $STEALS; do for r in $(seq 1 "$REPS"); do echo "$S $r"; done; done | shuf)
while read -r S REP; do
  echo "$S" > $P/wg_steal
  read B0 S0 SI0 < <(cpu_snap); T0=$(date +%s.%N)
  OUT=$(ssh -n -o StrictHostKeyChecking=no "$GEN" \
        "ip netns exec ns_c1 iperf3 -c 10.0.0.1 -p 5202 -P 4 -t $DUR -J 2>/dev/null" \
        | python3 -c "import json,sys; d=json.load(sys.stdin)['end']; print('%.4f %d'%(d['sum_received']['bits_per_second']/1e9, d['sum_sent'].get('retransmits',0)))")
  T1=$(date +%s.%N); read B1 S1 SI1 < <(cpu_snap)
  read GBPS RTX <<< "$OUT"
  WALL=$(awk -v a=$T0 -v b=$T1 'BEGIN{print (b-a>0? b-a : 1)}')
  SOFT_CE=$(awk -v d=$((S1-S0))  -v w=$WALL -v h=$HZ 'BEGIN{printf "%.3f", d/(w*h)}')
  SYS_CE=$(awk  -v d=$((SI1-SI0)) -v w=$WALL -v h=$HZ 'BEGIN{printf "%.3f", d/(w*h)}')
  BUSY_CE=$(awk -v d=$((B1-B0))  -v w=$WALL -v h=$HZ 'BEGIN{printf "%.3f", d/(w*h)}')
  DM=$(dmesg | tail -n +$((DMESG_BASE+1)) | grep -ciE "rcu|stall|hung|soft lockup|BUG|WARNING" || true)
  echo "$(date -Is),$SRC,$S,$REP,${GBPS:-NA},${RTX:-NA},$SOFT_CE,$SYS_CE,$BUSY_CE,$DM" >> "$CSV"
  printf "wg_steal=%-3s rep=%s | %s Gb/s | rtx=%-5s | soft=%s busy=%s CE | dmesg=%s\n" \
    "$S" "$REP" "${GBPS:-NA}" "${RTX:-NA}" "$SOFT_CE" "$BUSY_CE" "$DM" >&2
  sleep 3
done <<< "$ORDER"

echo 0 > $P/wg_steal
pkill -f 'iperf3 -s' 2>/dev/null
echo "ARTIFACT $CSV  (srcversion $SRC)"
