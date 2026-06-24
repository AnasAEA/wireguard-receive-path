#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# ONE run: loads module $MOD, drives N peers, captures BOTH aggregate throughput
# (via genload_json.sh on gen) AND the wasted-poll fraction (bpftrace on dut) in the
# same run. Emits one CSV line:  CSV,module,peers,run,gbps,wasted,useful,wasted_frac,src
# Designed to be called repeatedly by run_sweep.sh.
set -uo pipefail
MOD=${1:?usage: measure_run.sh module N [RUN] [DUR] [STREAMS] [GEN]}
N=${2:?need N}
RUN=${3:-1}
DUR=${4:-20}
STREAMS=${5:-4}
GEN=${6:-gen}
KO="$HOME/wireguard_${MOD}.ko"
ip link del wg0 2>/dev/null || true
rmmod wireguard 2>/dev/null || true
insmod "$KO"
bash "$HOME/setup_dut_peers.sh" "$N" >/dev/null
SRC=$(cat /sys/module/wireguard/srcversion)
pkill -f 'iperf3 -s' 2>/dev/null
sleep 1
for i in $(seq 0 $((N-1))); do iperf3 -s -p $((5201+i)) -D; done
GBPS_FILE=$(mktemp)
ssh -o StrictHostKeyChecking=no "$GEN" "bash /tmp/genload_json.sh $N $DUR $STREAMS" > "$GBPS_FILE" 2>/dev/null &
LOAD=$!
DURP=$((DUR+3))
OUT=$(bpftrace -e '
kretprobe:wg_packet_rx_poll /retval==0/ { @w += 1; }
kretprobe:wg_packet_rx_poll /retval>0/  { @u += 1; }
interval:s:'"$DURP"' { printf("WU %lld %lld\n", @w, @u); exit(); }' 2>/dev/null)
wait "$LOAD" 2>/dev/null
pkill -f 'iperf3 -s' 2>/dev/null
W=$(echo "$OUT" | awk '/^WU/{print $2}')
U=$(echo "$OUT" | awk '/^WU/{print $3}')
GBPS=$(awk '/^GBPS/{print $2}' "$GBPS_FILE")
rm -f "$GBPS_FILE"
: "${W:=0}" "${U:=0}" "${GBPS:=NA}"
FRAC=$(awk "BEGIN{ if ($W+$U>0) printf \"%.4f\", $W/($W+$U); else print \"NA\" }")
echo "CSV,$MOD,$N,$RUN,$GBPS,$W,$U,$FRAC,$SRC"
