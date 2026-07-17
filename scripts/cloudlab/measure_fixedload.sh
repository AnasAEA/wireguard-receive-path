#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo env AUDITED_HEAD="${AUDITED_HEAD:-}" bash "$0" "$@"
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
# timestamps of the CPU snapshots. Gate B validity requires every
# condition's exact-window delivered load to remain within +-5% of the
# configured target load (default 3.8 Gb/s), in addition to the 1.5%
# within-block paired-load gate — both enforced by analyze_confirm.py
# (--target-load overrides the target ONLY for a run that was intentionally
# predeclared at a different load, never to rescue observed data). wg0 rx_bytes counts inner (plaintext)
# bytes delivered post-decryption — the delivered WireGuard traffic — and
# includes the probe's ~1 Mb/s (<0.03% of 3.8 Gb/s, identical per condition).
# iperf sum_received (full ~70 s bulk incl. ramp) is kept as SECONDARY
# evidence only, in load_iperf_gbps + archived JSON. The latency window is a
# subset of [T0,T1] (sockperf starts ~0.3 s after T0, ssh setup).
#
# UDP LATENCY VALIDITY (blocker 3 + second audit §5): raw sockperf output is
# archived per run in the _raw/ dir; the CSV separates sockperf's [Total Run]
# counters (include warm-up; context only) from the [Valid Duration] section
# (the window the latency distribution actually covers): lat_duration_s,
# valid_sent/recv/dropped/dup/ooo_msgs, lat_n. ONLY valid-period fields feed
# the loss and sample-support gates in analyze_confirm.py. If the installed
# sockperf does not print a parseable [Valid Duration] section, the row FAILS
# here (raw output preserved) rather than silently mixing denominators — the
# one-block smoke exists to catch exactly that. Payload is EXPLICIT (MSGSIZE,
# default 64 B); percentile columns are *_half_rtt_us (ping-pong = RTT/2).
#
# CPU-ONLY MODE (coordinator-approved 2026-07-17, after the sockperf smoke
# failure): CPU_ONLY=1 turns gate B into a matched-delivered-load CPU
# confirmation with NO latency probe at all — no sockperf server, no client,
# no latency columns, no fabricated values. The measured window is the same
# [T0,T1] pair of byte+CPU snapshots, held open by 'sleep DUR' instead of
# the probe. Everything else is untouched: bulk cap + 5 s stabilization,
# liveness ping, identical warm-up, knob readbacks, classifier/steal counter
# resets+reads (descriptive), per-core capture, per-run dmesg deltas, raw
# iperf JSON, fail-closed aborts. LOAD defaults to 3.58 in this mode: the
# APPLICATION-level pacing that lands the delivered wg0 rx_bytes window rate
# on the 3.8 Gb/s scientific target (inner IP bytes carry ~6% header +
# retransmit overhead over iperf payload — measured 2026-07-17). Artifacts
# are fixedload_cpu_* / fixedload_cpu_smoke_* and carry cpu_only/probe_mode
# markers in both the CSV and .meta; analyze with --cpu-only.
#
# PROVENANCE GUARD: refuses to run without a clean-tree ~/HARNESS_GITREV
# stamp (see NEXT_STEPS step 0). BLOCKS != 8 renames artifacts to
# *_smoke_* so a shortened smoke can never pass as a final artifact.
#
# Artifacts: $CSV, $CSV.meta, $CSV.percore, $CSV.dmesg, ${CSV%.csv}_raw/
# (iperf JSON per run; + raw sockperf in legacy probe mode).
#   sudo -v && nohup sudo -n bash ~/measure_fixedload.sh > ~/fixedload_run.log 2>&1 &
set -euo pipefail
exec 9>/tmp/wg_confirmation_campaign.lock
flock -n 9 || { echo "FATAL: another confirmation campaign (gate A or B) is running" >&2; exit 1; }
BLOCKS=${1:-8}
DUR=${2:-60}
GEN=${3:-gen}
NIC=${4:-$(ip -br addr | awk '/192\.168\.1\.1\//{print $1; exit}')}
[ -n "$NIC" ] || { echo "FATAL: cannot find the experiment NIC (192.168.1.1)" >&2; exit 1; }
CPU_ONLY=${CPU_ONLY:-0}      # 1 = CPU-only mode (no latency probe); must be exactly 0 or 1
case "$CPU_ONLY" in 0|1) ;; *) echo "FATAL: CPU_ONLY must be exactly 0 or 1 (got '$CPU_ONLY')" >&2; exit 1;; esac
if [ "$CPU_ONLY" = "1" ]; then
  LOAD=${LOAD:-3.58}         # application cap that delivers ~3.8 Gb/s of wg0 rx_bytes
else
  LOAD=${LOAD:-3.8}          # Gb/s: total bulk cap over the single tunnel (legacy)
fi
STREAMS=${STREAMS:-4}
MPS=${MPS:-2000}             # probe msgs/s (legacy probe mode only)
MSGSIZE=${MSGSIZE:-64}       # explicit sockperf payload bytes (legacy probe mode only)
WGDIAG=${WGDIAG:-1}
CONDS=(off both steal4 bsteal4)
KO="$HOME/wireguard_trigger.ko"
NAME=fixedload; [ "$CPU_ONLY" = "1" ] && NAME=fixedload_cpu
[ "$BLOCKS" -eq 8 ] || NAME=${NAME}_smoke   # shortened run = smoke artifact
TS=$(date +%Y%m%d_%H%M%S)
CSV="$HOME/${NAME}_$TS.csv"; PCF="$CSV.percore"; META="$CSV.meta"; DMESGF="$CSV.dmesg"
RAW="$HOME/${NAME}_${TS}_raw"
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
  # scoped to THIS campaign's flows (namespace/dest/port), not host-wide names
  if [ -n "$BPID" ]; then kill "$BPID" 2>/dev/null || true; wait "$BPID" 2>/dev/null || true; fi
  ssh -n -o StrictHostKeyChecking=no "$GEN" \
    "pkill -f 'iperf3 -c 10.0.0.1 -p 5202'; pkill -f 'sockperf ping-pong -i 10.0.0.1 -p $LPORT'" \
    2>/dev/null || true
  for p in wg_supp wg_headwake wg_trig_k wg_decrypt_delay_ns wg_diag wg_steal; do
    echo 0 > $P/$p 2>/dev/null || true; done
  ethtool -N "$NIC" rx-flow-hash udp4 sd >/dev/null 2>&1 || true
  pkill -f 'iperf3 -s -p 520' 2>/dev/null || true
  pkill -f "sockperf server -i 10.0.0.1 -p $LPORT" 2>/dev/null || true
  echo "cleanup done — partial artifacts preserved under $CSV* and $RAW/" >&2; }
trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM

# Provenance stamp contract (final audit §2 + duplicate-field fix): the stamp
# must be EXACTLY one line, byte-identical to the canonical form the step 0
# preflight writes:
#   commit=<AUDITED_HEAD> branch=cloudlab-receive-path-findings dirty=0
# Whole-line comparison rejects missing, duplicated, unknown or reordered
# fields, extra tokens/whitespace, multi-line stamps, wrong branch, dirty!=0
# and a wrong commit in one check; malformed input is never normalized.
validate_stamp(){ local f=$1 expected actual nlines
  [ -n "${AUDITED_HEAD:-}" ] || { echo "AUDITED_HEAD is not set — run via: sudo -n env AUDITED_HEAD=<approved-hash> bash $0 (NEXT_STEPS step 0)"; return 1; }
  [ -f "$f" ] || { echo "missing provenance stamp $f (NEXT_STEPS step 0)"; return 1; }
  nlines=$(grep -c '' "$f")   # counts a final line even without trailing newline
  [ "$nlines" -eq 1 ] || { echo "stamp must be exactly one line, got $nlines — re-run the step 0 preflight"; return 1; }
  actual=$(head -1 "$f")
  expected="commit=$AUDITED_HEAD branch=cloudlab-receive-path-findings dirty=0"
  [ "$actual" = "$expected" ] || { echo "invalid provenance stamp — expected: '$expected'  actual: '$actual' — re-run the step 0 preflight"; return 1; }
  echo "$actual"
}
GITREV=$(validate_stamp "$HOME/HARNESS_GITREV") || fatal "provenance: $GITREV"

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
  END{printf "%d %d %d\n", tot-idle, soft, sysirq}' /proc/stat; }
  # \n matters: read(1) returns 1 at EOF-without-newline, which set -e
  # turns into a silent abort (found by the gate A smoke, 2026-07-16)
percore_snap(){ awk '/^cpu[0-9]/{print $1, $2+$3+$4+$7+$8+$9, $8, $4+$7+$8}' /proc/stat; }

ip link del wg0 2>/dev/null||true; rmmod wireguard 2>/dev/null||true
insmod "$KO"
SRC=$(cat $P/../srcversion 2>/dev/null || echo NA)
[ -f $P/wg_steal ] || fatal "module has no wg_steal (old build?)"
ethtool -N "$NIC" rx-flow-hash udp4 sdfn >/dev/null 2>&1 || true  # irrelevant for 1 tunnel, kept for parity
bash "$HOME/setup_dut_peers.sh" 8 >/dev/null
pkill -f 'iperf3 -s -p 520' 2>/dev/null || true
pkill -f "sockperf server -i 10.0.0.1 -p $LPORT" 2>/dev/null || true; sleep 1
for i in $(seq 0 7); do iperf3 -s -p $((5201+i)) -D; done
if [ "$CPU_ONLY" != "1" ]; then
  ( sockperf server -i 10.0.0.1 -p $LPORT >/dev/null 2>&1 & ); sleep 1   # UDP server (legacy probe mode)
fi
ssh -n -o StrictHostKeyChecking=no "$GEN" \
  "for i in \$(seq 0 7); do ip netns exec ns_c\$i ping -c1 -W2 10.0.0.1 >/dev/null 2>&1 & done; wait" || true
HS_SETUP=$(wg show wg0 latest-handshakes | awk '$2>0{c++} END{print c+0}')

{ echo "campaign=fixedload_gateB"
  echo "started=$(date -Is)"
  echo "hostname=$(hostname)"
  echo "kernel=$(uname -r)"
  echo "harness_gitrev=$GITREV"
  echo "audited_head=$AUDITED_HEAD"
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
  if [ "$CPU_ONLY" = "1" ]; then
    echo "cpu_only=1"; echo "probe_mode=none"
    echo "application_cap_gbps=$LOAD"
    echo "delivered_target_metric=wg0_rx_bytes_exact_window"
    echo "delivered_target_gbps=3.8"
    echo "absolute_tolerance_pct=5"
    echo "paired_tolerance_pct=1.5"
  else
    echo "sockperf_mps=$MPS"; echo "sockperf_msgsize=$MSGSIZE"
    echo "sockperf_latency_convention=half_rtt"
  fi
  echo "wgdiag=$WGDIAG"; echo "conds=${CONDS[*]}"
  echo "setup_handshakes=$HS_SETUP/8"
  echo "load_counter=wg0/statistics/rx_bytes (inner plaintext bytes delivered post-decryption, incl ~1 Mb/s probe)"
} > "$META"

if [ "$CPU_ONLY" = "1" ]; then
  # no latency columns at all — none are measured, none are fabricated
  echo "date,srcversion,block,position,cond,knobs,cpu_only,probe_mode,load_window_gbps,load_iperf_gbps,window_s,retransmits,softirq_ce,system_ce,total_busy_ce,ping_ms,hs_age_s,unc_n,unc_total_ns,steal_pulled,steal_unblocked,steal_dryruns,dmesg_new,raw_ref" > "$CSV"
else
  echo "date,srcversion,block,position,cond,knobs,load_window_gbps,load_iperf_gbps,window_s,retransmits,total_run_sent_msgs,total_run_recv_msgs,lat_duration_s,valid_sent_msgs,valid_recv_msgs,valid_dropped_msgs,valid_dup_msgs,valid_ooo_msgs,lat_n,p50_half_rtt_us,p90_half_rtt_us,p99_half_rtt_us,p999_half_rtt_us,max_half_rtt_us,softirq_ce,system_ce,total_busy_ce,ping_ms,hs_age_s,unc_n,unc_total_ns,steal_pulled,steal_unblocked,steal_dryruns,dmesg_new,raw_ref" > "$CSV"
fi
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
    if [ "$CPU_ONLY" = "1" ]; then
      sleep "$DUR"                              # window held open; no probe
    else
      ssh -n -o StrictHostKeyChecking=no "$GEN" \
        "sudo ip netns exec ns_c1 sockperf ping-pong -i 10.0.0.1 -p $LPORT -t $DUR --mps=$MPS --msg-size $MSGSIZE 2>&1" \
        | sed -r 's/\x1b\[[0-9;]*m//g' > "$SPF" \
        || fatal "sockperf probe failed (blk=$BLK cond=$COND) — raw in $SPF"
    fi
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
    if [ "$CPU_ONLY" != "1" ]; then
      # [Total Run] includes warm-up: context only. [Valid Duration] is the
      # window the latency distribution covers: ONLY these fields feed the
      # loss/support gates. A missing/zero valid-period field is a sockperf
      # format incompatibility -> fail the row (raw preserved), never fall
      # back to Total Run denominators.
      TRS=$(awk -F'[;= ]+' '/\[Total Run\]/{for(i=1;i<=NF;i++) if($i=="SentMessages") print $(i+1)}' "$SPF" | head -1)
      TRR=$(awk -F'[;= ]+' '/\[Total Run\]/{for(i=1;i<=NF;i++) if($i=="ReceivedMessages") print $(i+1)}' "$SPF" | head -1)
      VDT=$(awk -F'[;= ]+' '/\[Valid Duration\]/{for(i=1;i<=NF;i++) if($i=="RunTime") print $(i+1)}' "$SPF" | head -1)
      VDS=$(awk -F'[;= ]+' '/\[Valid Duration\]/{for(i=1;i<=NF;i++) if($i=="SentMessages") print $(i+1)}' "$SPF" | head -1)
      VDR=$(awk -F'[;= ]+' '/\[Valid Duration\]/{for(i=1;i<=NF;i++) if($i=="ReceivedMessages") print $(i+1)}' "$SPF" | head -1)
      awk -v x="${VDT:-}" 'BEGIN{exit !(x+0>0)}' || fatal "sockperf [Valid Duration] RunTime missing/zero (blk=$BLK cond=$COND) — format incompatibility? raw: $SPF"
      awk -v x="${VDS:-}" 'BEGIN{exit !(x+0>0)}' || fatal "sockperf [Valid Duration] SentMessages missing/zero (blk=$BLK cond=$COND) — raw: $SPF"
      awk -v x="${VDR:-}" 'BEGIN{exit !(x+0>0)}' || fatal "sockperf [Valid Duration] ReceivedMessages missing/zero (blk=$BLK cond=$COND) — raw: $SPF"
      DROP=$(sed -n 's/.*dropped messages = \([0-9]*\).*/\1/p' "$SPF" | head -1)
      DUP=$(sed -n 's/.*duplicated messages = \([0-9]*\).*/\1/p' "$SPF" | head -1)
      OOO=$(sed -n 's/.*out-of-order messages = \([0-9]*\).*/\1/p' "$SPF" | head -1)
      P50=$(awk '/percentile 50.000/{print $NF}' "$SPF")
      P90=$(awk '/percentile 90.000/{print $NF}' "$SPF")
      P99=$(awk '/percentile 99.000/{print $NF}' "$SPF")
      P999=$(awk '/percentile 99.900/{print $NF}' "$SPF")
      PMAX=$(awk '/<MAX> observation/{print $NF}' "$SPF")
      NOBS=$(awk '/observations/{for(i=1;i<=NF;i++) if($i=="Total") print $(i+1)}' "$SPF" | head -1)
    fi
    [ "$RX1" -gt "$RX0" ] || fatal "wg0 rx_bytes did not advance over the window (blk=$BLK cond=$COND): tunnel delivered nothing"
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
    if [ "$CPU_ONLY" = "1" ]; then
      echo "$(date -Is),$SRC,$BLK,$POS,$COND,$KNOBS,1,none,$RXG,$IPG,$WALL,$RTX,$SOFT_CE,$SYS_CE,$BUSY_CE,$PING_MS,$HS_AGE,$UN,$UT,$SP,$SU,$SD,$DM,$(basename "$IPJ")" >> "$CSV"
      printf "blk=%-2s pos=%s cond=%-7s | win=%sG (iperf %sG) | soft=%s busy=%s | dmesg=%s\n" \
        "$BLK" "$POS" "$COND" "$RXG" "$IPG" "$SOFT_CE" "$BUSY_CE" "$DM" >&2
    else
      echo "$(date -Is),$SRC,$BLK,$POS,$COND,$KNOBS,$RXG,$IPG,$WALL,$RTX,${TRS:-NA},${TRR:-NA},$VDT,$VDS,$VDR,${DROP:-NA},${DUP:-NA},${OOO:-NA},${NOBS:-NA},${P50:-NA},${P90:-NA},${P99:-NA},${P999:-NA},${PMAX:-NA},$SOFT_CE,$SYS_CE,$BUSY_CE,$PING_MS,$HS_AGE,$UN,$UT,$SP,$SU,$SD,$DM,$(basename "$IPJ");$(basename "$SPF")" >> "$CSV"
      printf "blk=%-2s pos=%s cond=%-7s | win=%sG (iperf %sG) | p99=%-7s p999=%-8s n=%-7s drop=%-3s | soft=%s busy=%s | dmesg=%s\n" \
        "$BLK" "$POS" "$COND" "$RXG" "$IPG" "${P99:-NA}" "${P999:-NA}" "${NOBS:-NA}" "${DROP:-NA}" "$SOFT_CE" "$BUSY_CE" "$DM" >&2
    fi
    sleep 3
  done
done

echo "finished=$(date -Is)" >> "$META"
if [ "$CPU_ONLY" = "1" ]; then
  echo "ARTIFACT $CSV  (srcversion $SRC, blocks=$BLOCKS, load=${LOAD}G app cap, cpu_only=1, probe=none, wg_diag=$WGDIAG)"
else
  echo "ARTIFACT $CSV  (srcversion $SRC, blocks=$BLOCKS, load=${LOAD}G, mps=$MPS, msgsize=$MSGSIZE, wg_diag=$WGDIAG)"
fi
echo "ARTIFACT $META $PCF $DMESGF $RAW/"
