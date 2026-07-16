#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# Phase D confirmation, gate B — matched-load CPU + same-tunnel tail latency.
# Single tunnel, bulk CAPPED at LOAD Gb/s (default 3.8 — below the ~4.2 off
# ceiling, so every condition can hold the same load), plus a low-rate
# sockperf UDP ping-pong over the SAME tunnel (ns_c1 -> 10.0.0.1: same outer
# 5-tuple, same RX queue, same NAPI context as the bulk). Paired blocks
# (off / both / steal4 / bsteal4), order re-shuffled per block; analysis on
# within-block deltas (analyze_confirm.py, decision rules pre-declared there).
# WGDIAG=1 (default): classifier + steal counters, measure_steal.sh
# methodology; the classifier is biased under wg_supp (both/bsteal4).
#
# FAIL-CLOSED DESIGN (coordinator audit 2026-07-16): set -e; all six knobs
# written AND read back per condition (readbacks in the CSV row); identical
# post-condition warm-up; shared campaign lock with gate A; seconds-resolution
# artifact names, never overwritten; failures abort but preserve partials.
#
# EXACT-WINDOW LOAD (blocker 2): the matched-load validity number is
# load_window_gbps = delta(wg0 rx_bytes)*8/(T1-T0), read at the very
# timestamps of the CPU snapshots. wg0 rx_bytes counts inner (plaintext)
# bytes delivered post-decryption — the delivered WireGuard traffic — and
# includes the probe's ~1 Mb/s (<0.03% of 3.8 Gb/s, identical per condition).
# iperf sum_received (full ~70 s bulk incl. ramp) is kept as SECONDARY
# evidence only, in load_iperf_gbps + archived JSON. The latency window is a
# subset of [T0,T1] (sockperf starts ~0.3 s after T0, ssh setup).
#
# UDP LATENCY VALIDITY (blocker 3): raw sockperf output is archived per run
# in ${CSV%.csv}_raw/; sent/received/dropped/duplicated/out-of-order counts
# and the observation count are parsed into the CSV; payload is EXPLICIT
# (MSGSIZE, default 64 B); percentile columns are named *_half_rtt_us
# because sockperf ping-pong reports latency = RTT/2. Loss / sample-support
# thresholds are enforced by analyze_confirm.py, not silently here.
#
# Artifacts: $CSV, $CSV.meta, $CSV.percore, $CSV.dmesg, ${CSV%.csv}_raw/
# (iperf JSON + raw sockperf per run).
#   sudo -v && nohup sudo -n bash ~/measure_fixedload.sh > ~/fixedload_run.log 2>&1 &
set -euo pipefail
exec 9>/tmp/wg_confirmation_campaign.lock
flock -n 9 || { echo "FATAL: another confirmation campaign (gate A or B) is running" >&2; exit 1; }
BLOCKS=${1:-8}
DUR=${2:-60}
GEN=${3:-gen}
NIC=${4:-$(ip -br addr | awk '/192\.168\.1\.1\//{print $1; exit}')}
[ -n "$NIC" ] || { echo "FATAL: cannot find the experiment NIC (192.168.1.1)" >&2; exit 1; }
LOAD=${LOAD:-3.8}            # Gb/s: total bulk cap over the single tunnel
STREAMS=${STREAMS:-4}
MPS=${MPS:-2000}             # probe msgs/s: 2000 x 60 s = 120k obs, p99.9 rests on ~120
MSGSIZE=${MSGSIZE:-64}       # explicit sockperf payload bytes
WGDIAG=${WGDIAG:-1}
CONDS=(off both steal4 bsteal4)
KO="$HOME/wireguard_trigger.ko"
TS=$(date +%Y%m%d_%H%M%S)
CSV="$HOME/fixedload_$TS.csv"; PCF="$CSV.percore"; META="$CSV.meta"; DMESGF="$CSV.dmesg"
RAW="$HOME/fixedload_${TS}_raw"
for f in "$CSV" "$PCF" "$META" "$DMESGF" "$RAW"; do
  if [ -e "$f" ]; then echo "FATAL: refusing to overwrite existing artifact $f" >&2; exit 1; fi
done
mkdir "$RAW"
P=/sys/module/wireguard/parameters
WGRX=/sys/class/net/wg0/statistics/rx_bytes
HZ=$(getconf CLK_TCK); LPORT=11111
PSM=$(awk -v l="$LOAD" -v s="$STREAMS" 'BEGIN{printf "%d", l*1000/s}')   # Mbit/s per stream
BPID=""

fatal(){ echo "FATAL: $*" >&2; exit 1; }

cleanup(){ local p
  if [ -n "$BPID" ]; then kill "$BPID" 2>/dev/null || true; wait "$BPID" 2>/dev/null || true; fi
  ssh -n -o StrictHostKeyChecking=no "$GEN" "pkill -f 'iperf3 -c'; pkill sockperf" 2>/dev/null || true
  for p in wg_supp wg_headwake wg_trig_k wg_decrypt_delay_ns wg_diag wg_steal; do
    echo 0 > $P/$p 2>/dev/null || true; done
  ethtool -N "$NIC" rx-flow-hash udp4 sd >/dev/null 2>&1 || true
  pkill -f 'iperf3 -s' 2>/dev/null || true; pkill sockperf 2>/dev/null || true
  echo "cleanup done — partial artifacts preserved under $CSV* and $RAW/" >&2; }
trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM

apply_cond(){ local supp=0 head=0 steal=0 k v got
  case "$1" in
    off) ;; both) supp=1; head=1;; steal4) steal=4;; bsteal4) supp=1; head=1; steal=4;;
    *) fatal "unknown condition '$1'";;
  esac
  for kv in "wg_supp $supp" "wg_headwake $head" "wg_steal $steal" \
            "wg_diag $WGDIAG" "wg_decrypt_delay_ns 0" "wg_trig_k 0"; do
    k=${kv% *}; v=${kv#* }
    echo "$v" > "$P/$k"
    got=$(cat "$P/$k")
    [ "$got" = "$v" ] || fatal "knob readback mismatch: $k=$got, expected $v (cond $1)"
  done
  KNOBS="supp=$(cat $P/wg_supp);headwake=$(cat $P/wg_headwake);steal=$(cat $P/wg_steal);diag=$(cat $P/wg_diag);delay=$(cat $P/wg_decrypt_delay_ns);trig_k=$(cat $P/wg_trig_k)"
}

cpu_snap(){ awk '/^cpu[0-9]/{u=$2;n=$3;s=$4;id=$5;io=$6;irq=$7;sq=$8;st=$9;
  tot+=u+n+s+id+io+irq+sq+st; idle+=id+io; soft+=sq; sysirq+=s+irq+sq}
  END{printf "%d %d %d", tot-idle, soft, sysirq}' /proc/stat; }
percore_snap(){ awk '/^cpu[0-9]/{print $1, $2+$3+$4+$7+$8+$9, $8, $4+$7+$8}' /proc/stat; }

ip link del wg0 2>/dev/null||true; rmmod wireguard 2>/dev/null||true
insmod "$KO"
SRC=$(cat $P/../srcversion 2>/dev/null || echo NA)
[ -f $P/wg_steal ] || fatal "module has no wg_steal (old build?)"
ethtool -N "$NIC" rx-flow-hash udp4 sdfn >/dev/null 2>&1 || true  # irrelevant for 1 tunnel, kept for parity
bash "$HOME/setup_dut_peers.sh" 8 >/dev/null
pkill -f 'iperf3 -s' 2>/dev/null || true; pkill sockperf 2>/dev/null || true; sleep 1
for i in $(seq 0 7); do iperf3 -s -p $((5201+i)) -D; done
( sockperf server -i 10.0.0.1 -p $LPORT >/dev/null 2>&1 & ); sleep 1     # UDP server
ssh -n -o StrictHostKeyChecking=no "$GEN" \
  "for i in \$(seq 0 7); do ip netns exec ns_c\$i ping -c1 -W2 10.0.0.1 >/dev/null 2>&1 & done; wait" || true
HS_SETUP=$(wg show wg0 latest-handshakes | awk '$2>0{c++} END{print c+0}')

{ echo "campaign=fixedload_gateB"
  echo "started=$(date -Is)"
  echo "hostname=$(hostname)"
  echo "kernel=$(uname -r)"
  echo "harness_gitrev=$(cat "$HOME/HARNESS_GITREV" 2>/dev/null || echo unknown)"
  echo "module_srcversion=$SRC"
  echo "nic=$NIC"
  echo "nic_driver=$(ethtool -i "$NIC" 2>/dev/null | awk '/^driver:/{print $2}')"
  echo "rx_queues=$(ls -d /sys/class/net/"$NIC"/queues/rx-* 2>/dev/null | wc -l)"
  echo "flow_hash=$(ethtool -n "$NIC" rx-flow-hash udp4 2>/dev/null | tr '\n' ';')"
  echo "cpu_model=$(awk -F: '/model name/{gsub(/^ /,"",$2); print $2; exit}' /proc/cpuinfo)"
  echo "cpu_count=$(nproc)"
  echo "governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo NA)"
  echo "irqbalance=$(systemctl is-active irqbalance 2>/dev/null || echo NA)"
  echo "blocks=$BLOCKS"; echo "window_s=$DUR"; echo "streams=$STREAMS"
  echo "target_load_gbps=$LOAD"; echo "per_stream_mbit=$PSM"
  echo "sockperf_mps=$MPS"; echo "sockperf_msgsize=$MSGSIZE"
  echo "sockperf_latency_convention=half_rtt"
  echo "wgdiag=$WGDIAG"; echo "conds=${CONDS[*]}"
  echo "setup_handshakes=$HS_SETUP/8"
  echo "load_counter=wg0/statistics/rx_bytes (inner plaintext bytes delivered post-decryption, incl ~1 Mb/s probe)"
} > "$META"

echo "date,srcversion,block,position,cond,knobs,load_window_gbps,load_iperf_gbps,window_s,retransmits,sent_msgs,recv_msgs,dropped_msgs,dup_msgs,ooo_msgs,lat_n,p50_half_rtt_us,p90_half_rtt_us,p99_half_rtt_us,p999_half_rtt_us,max_half_rtt_us,softirq_ce,system_ce,total_busy_ce,ping_ms,hs_age_s,unc_n,unc_total_ns,steal_pulled,steal_unblocked,steal_dryruns,dmesg_new,raw_ref" > "$CSV"
echo "timestamp block position cond cpu busy_ce softirq_ce system_ce" > "$PCF"
: > "$DMESGF"

for BLK in $(seq 1 "$BLOCKS"); do
  ORDER=($(shuf -e "${CONDS[@]}"))
  for POS in 1 2 3 4; do
    COND=${ORDER[$((POS-1))]}
    apply_cond "$COND"
    PING_MS=$( (ssh -n -o StrictHostKeyChecking=no "$GEN" \
      "ip netns exec ns_c1 ping -c1 -W2 10.0.0.1 2>/dev/null || ip netns exec ns_c1 ping -c1 -W2 10.0.0.1 2>/dev/null" \
      || true) | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | head -1)
    [ -n "$PING_MS" ] || fatal "tunnel dead after applying cond=$COND (blk=$BLK)"
    ssh -n -o StrictHostKeyChecking=no "$GEN" \
      "ip netns exec ns_c1 iperf3 -c 10.0.0.1 -p 5202 -P $STREAMS -b ${PSM}M -t 6 >/dev/null 2>&1" \
      || fatal "warm-up iperf failed (blk=$BLK cond=$COND)"
    sleep 2
    IPJ="$RAW/iperf_b${BLK}p${POS}_${COND}.json"
    SPF="$RAW/sockperf_b${BLK}p${POS}_${COND}.txt"
    ssh -n -o StrictHostKeyChecking=no "$GEN" \
      "ip netns exec ns_c1 iperf3 -c 10.0.0.1 -p 5202 -P $STREAMS -b ${PSM}M -t $((DUR+15)) -J 2>/dev/null" \
      > "$IPJ" &
    BPID=$!; sleep 5                            # bulk running and stabilized before T0
    if [ "$WGDIAG" = "1" ]; then
      echo 0,0,0,0,0,0,0 > $P/wg_diag_stall_uncrypt
      for c in wg_diag_steal_pulled wg_diag_steal_unblocked wg_diag_steal_dryruns; do echo 0 > $P/$c; done
    fi
    DL0=$(dmesg | wc -l)
    RX0=$(cat "$WGRX"); PC0=$(percore_snap); read B0 S0 SI0 < <(cpu_snap); T0=$(date +%s.%N)
    ssh -n -o StrictHostKeyChecking=no "$GEN" \
      "sudo ip netns exec ns_c1 sockperf ping-pong -i 10.0.0.1 -p $LPORT -t $DUR --mps=$MPS --msg-size $MSGSIZE 2>&1" \
      | sed -r 's/\x1b\[[0-9;]*m//g' > "$SPF" \
      || fatal "sockperf probe failed (blk=$BLK cond=$COND) — raw in $SPF"
    T1=$(date +%s.%N); read B1 S1 SI1 < <(cpu_snap); PC1=$(percore_snap); RX1=$(cat "$WGRX")
    if [ "$WGDIAG" = "1" ]; then
      IFS=, read -r UN UT _ <<< "$(cat $P/wg_diag_stall_uncrypt)"
      SP=$(cat $P/wg_diag_steal_pulled); SU=$(cat $P/wg_diag_steal_unblocked); SD=$(cat $P/wg_diag_steal_dryruns)
    else UN=NA; UT=NA; SP=NA; SU=NA; SD=NA; fi
    wait "$BPID" || fatal "bulk iperf failed (blk=$BLK cond=$COND) — JSON in $IPJ"
    BPID=""
    OUT=$(python3 - "$IPJ" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["end"]
print("%.4f %d" % (d["sum_received"]["bits_per_second"]/1e9,
                   d["sum_sent"].get("retransmits", 0)))
PY
    ) || fatal "iperf JSON parse failed: $IPJ"
    read IPG RTX <<< "$OUT"
    SENT=$(awk -F'[;= ]+' '/\[Total Run\]/{for(i=1;i<=NF;i++) if($i=="SentMessages") print $(i+1)}' "$SPF" | head -1)
    RECV=$(awk -F'[;= ]+' '/\[Total Run\]/{for(i=1;i<=NF;i++) if($i=="ReceivedMessages") print $(i+1)}' "$SPF" | head -1)
    DROP=$(sed -n 's/.*dropped messages = \([0-9]*\).*/\1/p' "$SPF" | head -1)
    DUP=$(sed -n 's/.*duplicated messages = \([0-9]*\).*/\1/p' "$SPF" | head -1)
    OOO=$(sed -n 's/.*out-of-order messages = \([0-9]*\).*/\1/p' "$SPF" | head -1)
    P50=$(awk '/percentile 50.000/{print $NF}' "$SPF")
    P90=$(awk '/percentile 90.000/{print $NF}' "$SPF")
    P99=$(awk '/percentile 99.000/{print $NF}' "$SPF")
    P999=$(awk '/percentile 99.900/{print $NF}' "$SPF")
    PMAX=$(awk '/<MAX> observation/{print $NF}' "$SPF")
    NOBS=$(awk '/observations/{for(i=1;i<=NF;i++) if($i=="Total") print $(i+1)}' "$SPF" | head -1)
    WALL=$(awk -v a=$T0 -v b=$T1 'BEGIN{printf "%.3f", b-a}')
    RXG=$(awk -v r0=$RX0 -v r1=$RX1 -v w=$WALL 'BEGIN{printf "%.4f", (r1-r0)*8/w/1e9}')
    SOFT_CE=$(awk -v d=$((S1-S0))  -v w=$WALL -v h=$HZ 'BEGIN{printf "%.3f", d/(w*h)}')
    SYS_CE=$(awk  -v d=$((SI1-SI0)) -v w=$WALL -v h=$HZ 'BEGIN{printf "%.3f", d/(w*h)}')
    BUSY_CE=$(awk -v d=$((B1-B0))  -v w=$WALL -v h=$HZ 'BEGIN{printf "%.3f", d/(w*h)}')
    NEWDM=$(dmesg | tail -n +$((DL0+1)) | grep -E "rcu|stall|hung|soft lockup|BUG|WARNING" || true)
    DM=$(printf '%s' "$NEWDM" | grep -c . || true)
    if [ -n "$NEWDM" ]; then printf '=== %s blk=%s pos=%s cond=%s\n%s\n' \
      "$(date -Is)" "$BLK" "$POS" "$COND" "$NEWDM" >> "$DMESGF"; fi
    HS_AGE=$(wg show wg0 latest-handshakes | awk -v now="$(date +%s)" \
      '$2>0{a=now-$2; if(m==""||a<m)m=a} END{print (m==""? "NA" : m)}')
    PCJ=$(paste <(printf '%s\n' "$PC0") <(printf '%s\n' "$PC1"))
    echo "$PCJ" | awk '$1!=$5{exit 1}' || fatal "CPU topology changed (blk=$BLK cond=$COND)"
    echo "$PCJ" | awk -v ts="$(date -Is)" -v b=$BLK -v p=$POS -v c=$COND -v w=$WALL -v h=$HZ \
      '{printf "%s %s %s %s %s %.3f %.3f %.3f\n", ts,b,p,c,$1,($6-$2)/(w*h),($7-$3)/(w*h),($8-$4)/(w*h)}' >> "$PCF"
    echo "$(date -Is),$SRC,$BLK,$POS,$COND,$KNOBS,$RXG,$IPG,$WALL,$RTX,${SENT:-NA},${RECV:-NA},${DROP:-NA},${DUP:-NA},${OOO:-NA},${NOBS:-NA},${P50:-NA},${P90:-NA},${P99:-NA},${P999:-NA},${PMAX:-NA},$SOFT_CE,$SYS_CE,$BUSY_CE,$PING_MS,$HS_AGE,$UN,$UT,$SP,$SU,$SD,$DM,$(basename "$IPJ");$(basename "$SPF")" >> "$CSV"
    printf "blk=%-2s pos=%s cond=%-7s | win=%sG (iperf %sG) | p99=%-7s p999=%-8s n=%-7s drop=%-3s | soft=%s busy=%s | dmesg=%s\n" \
      "$BLK" "$POS" "$COND" "$RXG" "$IPG" "${P99:-NA}" "${P999:-NA}" "${NOBS:-NA}" "${DROP:-NA}" "$SOFT_CE" "$BUSY_CE" "$DM" >&2
    sleep 3
  done
done

echo "finished=$(date -Is)" >> "$META"
echo "ARTIFACT $CSV  (srcversion $SRC, blocks=$BLOCKS, load=${LOAD}G, mps=$MPS, msgsize=$MSGSIZE, wg_diag=$WGDIAG)"
echo "ARTIFACT $META $PCF $DMESGF $RAW/"
