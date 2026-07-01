#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# DECRYPT-COST SENSITIVITY (Alain 2026-06-25). CloudLab Xeons decrypt fast
# (T_decrypt~5-6µs), so the head clears quickly and the EoI fix is null. Hypothesis: on
# slower-crypto hardware the head stays UNCRYPTED longer => more wasted re-polls => the
# fix removes more and matters more. We test it with the wg_decrypt_delay_ns knob (busy-wait
# injected per decrypt, in the decrypt worker, poll cost untouched), sweeping T_decrypt and
# measuring wasted% + throughput for fix off vs both (two-sided). Maps the fix's payoff vs
# the decrypt:poll cost ratio.
#   sudo bash ~/measure_decrypt_sweep.sh 8
#   sudo bash ~/measure_decrypt_sweep.sh 32 "0 10000 20000 40000"
# Writes ~/decsweep_<ts>.csv : delay_ns,cond,gbps,polls,wasted,wasted_frac
set -uo pipefail
N=${1:-8}; DELAYS=${2:-"0 5000 10000 20000 40000"}; DUR=${3:-15}; GEN=${4:-gen}; NIC=${5:-enp6s0f0}
CONDS=${CONDS:-"off both"}
KO="$HOME/wireguard_trigger.ko"; TS=$(date +%Y%m%d_%H%M); CSV="$HOME/decsweep_$TS.csv"
GUARD=$((DUR+20))

cleanup(){ local p
  for p in wg_supp wg_headwake wg_trig_k wg_decrypt_delay_ns; do
    echo 0 > /sys/module/wireguard/parameters/$p 2>/dev/null || true; done
  ethtool -N "$NIC" rx-flow-hash udp4 sd >/dev/null 2>&1 || true
  pkill -f 'iperf3 -s' 2>/dev/null || true; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

set_cond() { local s=0 h=0; case "$1" in move) s=1 ;; root) h=1 ;; both) s=1; h=1 ;; esac
  echo $s > /sys/module/wireguard/parameters/wg_supp
  echo 0  > /sys/module/wireguard/parameters/wg_trig_k
  echo $h > /sys/module/wireguard/parameters/wg_headwake; }

ip link del wg0 2>/dev/null || true; rmmod wireguard 2>/dev/null || true
insmod "$KO"
ethtool -N "$NIC" rx-flow-hash udp4 sdfn >/dev/null 2>&1
bash "$HOME/setup_dut_peers.sh" "$N" >/dev/null
pkill -f 'iperf3 -s' 2>/dev/null; sleep 1
for i in $(seq 0 $((N-1))); do iperf3 -s -p $((5201+i)) -D; done
echo "delay_ns,cond,gbps,polls,wasted,wasted_frac" > "$CSV"
printf "\n%-9s %-5s %-8s %-9s\n" "delay_ns" "cond" "gbps" "wasted%" >&2

for D in $DELAYS; do
  echo "$D" > /sys/module/wireguard/parameters/wg_decrypt_delay_ns
  for cond in $CONDS; do
    set_cond "$cond"
    # throughput
    GBPS=$(timeout "$GUARD" ssh -o StrictHostKeyChecking=no "$GEN" \
        "bash /tmp/genload_json.sh $N $DUR 4" 2>/dev/null | grep -oE 'GBPS [0-9.]+' | awk '{print $2}')
    # wasted polls during a second, overlapping load window
    timeout "$GUARD" ssh -o StrictHostKeyChecking=no "$GEN" "bash /tmp/genload_json.sh $N $DUR 4" >/dev/null 2>&1 &
    sleep 2
    OUT=$(bpftrace -e '
      kretprobe:wg_packet_rx_poll { @polls++; if (retval==0) { @wasted++; } }
      interval:s:'"$DUR"' { printf("R %llu %llu\n", @polls, @wasted); exit(); }' 2>/dev/null | grep '^R')
    wait 2>/dev/null
    P=$(echo "$OUT" | awk '{print $2}'); W=$(echo "$OUT" | awk '{print $3}')
    WF=$(awk -v w="${W:-0}" -v p="${P:-1}" 'BEGIN{printf "%.3f", (p>0? w/p:0)}')
    echo "$D,$cond,${GBPS:-NA},${P:-0},${W:-0},$WF" >> "$CSV"
    printf "%-9s %-5s %-8s %-9s\n" "$D" "$cond" "${GBPS:-NA}" "$(awk -v f="$WF" 'BEGIN{printf "%.1f", f*100}')" >&2
  done
done
echo 0 > /sys/module/wireguard/parameters/wg_decrypt_delay_ns
ethtool -N "$NIC" rx-flow-hash udp4 sd >/dev/null 2>&1
pkill -f 'iperf3 -s' 2>/dev/null
echo "ARTIFACT $CSV"
