#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# Phase D confirmation, gate A — does Finding 8 replicate on a fresh node?
# Paired four-condition blocks (off / both / steal4 / bsteal4), uncapped
# single-tunnel (one tunnel = one 5-tuple = one RX queue), 30 s windows, the
# condition order re-shuffled inside every block. Analysis is on WITHIN-BLOCK
# deltas (analyze_confirm.py, where the decision rules are pre-declared).
# WGDIAG=0 (default) keeps EXACT parity with the headline sweep, which ran
# with wg_diag off. WGDIAG=1 additionally captures the E11-C classifier +
# steal counters — for a short mechanism run, not the primary replication;
# the classifier is biased under wg_supp (both/bsteal4).
#
# FAIL-CLOSED DESIGN (coordinator audit 2026-07-16): set -e; every knob
# (wg_supp/wg_headwake/wg_steal/wg_diag/wg_decrypt_delay_ns/wg_trig_k) is
# written AND read back per condition, readbacks stored in the CSV row; the
# per-condition warm-up runs AFTER the condition is applied (identical for all
# four); any measurement failure aborts the campaign (partial artifacts are
# preserved, never deleted); one shared lock stops gate A and gate B from
# overlapping; artifact names have seconds resolution and are never
# overwritten. Delivered load is ALSO measured over the exact T0-T1 CPU
# window from wg0 rx_bytes (inner/plaintext bytes delivered post-decryption;
# the window includes ~0.3 s of ssh setup, identically for every condition —
# iperf sum_received over its own 30 s test remains the primary throughput).
# dmesg is a true per-run delta, with matching lines archived in $CSV.dmesg.
#
# Artifacts: $CSV (rows), $CSV.meta (provenance), $CSV.percore (per-core CE
# with join keys), $CSV.dmesg (archived warning lines), ${CSV%.csv}_raw/
# (raw iperf JSON per run).
#   sudo -v && nohup sudo -n bash ~/measure_confirm.sh > ~/confirm_run.log 2>&1 &
set -euo pipefail
exec 9>/tmp/wg_confirmation_campaign.lock
flock -n 9 || { echo "FATAL: another confirmation campaign (gate A or B) is running" >&2; exit 1; }
BLOCKS=${1:-12}
DUR=${2:-30}
GEN=${3:-gen}
NIC=${4:-$(ip -br addr | awk '/192\.168\.1\.1\//{print $1; exit}')}
[ -n "$NIC" ] || { echo "FATAL: cannot find the experiment NIC (192.168.1.1)" >&2; exit 1; }
WGDIAG=${WGDIAG:-0}
CONDS=(off both steal4 bsteal4)
KO="$HOME/wireguard_trigger.ko"
TS=$(date +%Y%m%d_%H%M%S)
CSV="$HOME/confirm_$TS.csv"; PCF="$CSV.percore"; META="$CSV.meta"; DMESGF="$CSV.dmesg"
RAW="$HOME/confirm_${TS}_raw"
for f in "$CSV" "$PCF" "$META" "$DMESGF" "$RAW"; do
  if [ -e "$f" ]; then echo "FATAL: refusing to overwrite existing artifact $f" >&2; exit 1; fi
done
mkdir "$RAW"
P=/sys/module/wireguard/parameters
WGRX=/sys/class/net/wg0/statistics/rx_bytes
HZ=$(getconf CLK_TCK)
BPID=""

fatal(){ echo "FATAL: $*" >&2; exit 1; }

cleanup(){ local p
  if [ -n "$BPID" ]; then kill "$BPID" 2>/dev/null || true; wait "$BPID" 2>/dev/null || true; fi
  ssh -n -o StrictHostKeyChecking=no "$GEN" "pkill -f 'iperf3 -c'" 2>/dev/null || true
  for p in wg_supp wg_headwake wg_trig_k wg_decrypt_delay_ns wg_diag wg_steal; do
    echo 0 > $P/$p 2>/dev/null || true; done
  ethtool -N "$NIC" rx-flow-hash udp4 sd >/dev/null 2>&1 || true
  pkill -f 'iperf3 -s' 2>/dev/null || true
  echo "cleanup done — partial artifacts preserved under $CSV* and $RAW/" >&2; }
trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM

# Write every knob for the condition, read each back, abort on any mismatch.
# Leaves the readback string (semicolon-separated, CSV-safe) in $KNOBS.
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
pkill -f 'iperf3 -s' 2>/dev/null || true; sleep 1
for i in $(seq 0 7); do iperf3 -s -p $((5201+i)) -D; done
ssh -n -o StrictHostKeyChecking=no "$GEN" \
  "for i in \$(seq 0 7); do ip netns exec ns_c\$i ping -c1 -W2 10.0.0.1 >/dev/null 2>&1 & done; wait" || true
HS_SETUP=$(wg show wg0 latest-handshakes | awk '$2>0{c++} END{print c+0}')

{ echo "campaign=confirm_gateA"
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
  echo "blocks=$BLOCKS"; echo "window_s=$DUR"; echo "streams=4"
  echo "wgdiag=$WGDIAG"; echo "conds=${CONDS[*]}"
  echo "setup_handshakes=$HS_SETUP/8"
  echo "load_counter=wg0/statistics/rx_bytes (inner plaintext bytes delivered post-decryption)"
} > "$META"

echo "date,srcversion,block,position,cond,knobs,gbps,retransmits,rx_window_gbps,window_s,softirq_ce,system_ce,total_busy_ce,ping_ms,hs_age_s,unc_n,unc_total_ns,steal_pulled,steal_unblocked,steal_dryruns,dmesg_new,raw_ref" > "$CSV"
echo "timestamp block position cond cpu busy_ce softirq_ce system_ce" > "$PCF"
: > "$DMESGF"

for BLK in $(seq 1 "$BLOCKS"); do
  ORDER=($(shuf -e "${CONDS[@]}"))
  for POS in 1 2 3 4; do
    COND=${ORDER[$((POS-1))]}
    apply_cond "$COND"
    # liveness under THIS condition (2 attempts), before the warm-up
    PING_MS=$( (ssh -n -o StrictHostKeyChecking=no "$GEN" \
      "ip netns exec ns_c1 ping -c1 -W2 10.0.0.1 2>/dev/null || ip netns exec ns_c1 ping -c1 -W2 10.0.0.1 2>/dev/null" \
      || true) | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | head -1)
    [ -n "$PING_MS" ] || fatal "tunnel dead after applying cond=$COND (blk=$BLK)"
    # identical excluded warm-up, AFTER the condition is applied
    ssh -n -o StrictHostKeyChecking=no "$GEN" \
      "ip netns exec ns_c1 iperf3 -c 10.0.0.1 -p 5202 -P 4 -t 6 >/dev/null 2>&1" \
      || fatal "warm-up iperf failed (blk=$BLK cond=$COND)"
    sleep 2
    if [ "$WGDIAG" = "1" ]; then
      echo 0,0,0,0,0,0,0 > $P/wg_diag_stall_uncrypt
      for c in wg_diag_steal_pulled wg_diag_steal_unblocked wg_diag_steal_dryruns; do echo 0 > $P/$c; done
    fi
    DL0=$(dmesg | wc -l)
    IPJ="$RAW/iperf_b${BLK}p${POS}_${COND}.json"
    RX0=$(cat "$WGRX"); PC0=$(percore_snap); read B0 S0 SI0 < <(cpu_snap); T0=$(date +%s.%N)
    ssh -n -o StrictHostKeyChecking=no "$GEN" \
      "ip netns exec ns_c1 iperf3 -c 10.0.0.1 -p 5202 -P 4 -t $DUR -J 2>/dev/null" > "$IPJ" \
      || fatal "measured iperf failed (blk=$BLK cond=$COND)"
    T1=$(date +%s.%N); read B1 S1 SI1 < <(cpu_snap); PC1=$(percore_snap); RX1=$(cat "$WGRX")
    if [ "$WGDIAG" = "1" ]; then
      IFS=, read -r UN UT _ <<< "$(cat $P/wg_diag_stall_uncrypt)"
      SP=$(cat $P/wg_diag_steal_pulled); SU=$(cat $P/wg_diag_steal_unblocked); SD=$(cat $P/wg_diag_steal_dryruns)
    else UN=NA; UT=NA; SP=NA; SU=NA; SD=NA; fi
    OUT=$(python3 - "$IPJ" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["end"]
print("%.4f %d" % (d["sum_received"]["bits_per_second"]/1e9,
                   d["sum_sent"].get("retransmits", 0)))
PY
    ) || fatal "iperf JSON parse failed: $IPJ"
    read GBPS RTX <<< "$OUT"
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
    echo "$(date -Is),$SRC,$BLK,$POS,$COND,$KNOBS,$GBPS,$RTX,$RXG,$WALL,$SOFT_CE,$SYS_CE,$BUSY_CE,$PING_MS,$HS_AGE,$UN,$UT,$SP,$SU,$SD,$DM,$(basename "$IPJ")" >> "$CSV"
    printf "blk=%-2s pos=%s cond=%-7s | %s Gb/s (win %s) | rtx=%-5s | soft=%s busy=%s CE | dmesg=%s\n" \
      "$BLK" "$POS" "$COND" "$GBPS" "$RXG" "$RTX" "$SOFT_CE" "$BUSY_CE" "$DM" >&2
    sleep 3
  done
done

echo "finished=$(date -Is)" >> "$META"
echo "ARTIFACT $CSV  (srcversion $SRC, blocks=$BLOCKS, wg_diag=$WGDIAG)"
echo "ARTIFACT $META $PCF $DMESGF $RAW/"
