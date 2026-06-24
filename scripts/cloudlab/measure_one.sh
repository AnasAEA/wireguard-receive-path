#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# Measure the wasted-poll fraction for ONE (module, N) on the DUT.
# Swaps the wireguard module, rebuilds wg0+peers, drives load from GEN, and runs
# the bpftrace probe. Prints WASTED/USEFUL totals + the work_done histogram.
#
# Usage:  sudo bash measure_one.sh <stock|patched> <N> [DUR] [STREAMS] [GEN]
# Needs:  ~/wireguard_<mod>.ko, ~/setup_dut_peers.sh, gen:/tmp/genload.sh
set -uo pipefail

MOD=${1:?usage: measure_one.sh stock|patched N [DUR] [STREAMS] [GEN]}
N=${2:?need N}
DUR=${3:-20}
STREAMS=${4:-4}
GEN=${5:-gen}
KO="$HOME/wireguard_${MOD}.ko"

ip link del wg0 2>/dev/null || true
rmmod wireguard 2>/dev/null || true
insmod "$KO"
bash "$HOME/setup_dut_peers.sh" "$N" >/dev/null
SRC=$(cat /sys/module/wireguard/srcversion)

pkill -f 'iperf3 -s' 2>/dev/null
sleep 1
for i in $(seq 0 $((N-1))); do
    iperf3 -s -p $((5201+i)) -D
done

ssh -o StrictHostKeyChecking=no "$GEN" "bash /tmp/genload.sh $N $DUR $STREAMS" &
LOAD=$!

DURP=$((DUR+3))
bpftrace -e '
kretprobe:wg_packet_rx_poll /retval==0/ { @w += 1; }
kretprobe:wg_packet_rx_poll /retval>0/  { @u += 1; @batch = lhist(retval,0,64,4); }
interval:s:'"$DURP"' {
    printf("WASTED %lld USEFUL %lld\n", @w, @u);
    print(@batch);
    exit();
}'

wait "$LOAD" 2>/dev/null
pkill -f 'iperf3 -s' 2>/dev/null
echo "RESULT module=$MOD src=$SRC N=$N dur=$DUR streams=$STREAMS"
