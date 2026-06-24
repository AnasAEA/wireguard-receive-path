#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# Clean C_poll / C_deliver (E4): probe ONLY wg_packet_rx_poll (no decrypt probe),
# so poll durations aren't inflated by per-packet probe overhead.
# Usage:  sudo bash measure_pollcost.sh <stock|patched|diag> <N> [DUR] [STREAMS] [GEN]
set -uo pipefail
MOD=${1:?usage: measure_pollcost.sh stock|patched|diag N [DUR] [STREAMS] [GEN]}
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
kprobe:wg_packet_rx_poll   { @ps[tid] = nsecs; }
kretprobe:wg_packet_rx_poll /@ps[tid]/ {
    $d = nsecs - @ps[tid];
    @poll_avg_ns[retval] = avg($d);
    @poll_cnt[retval]    = count();
    delete(@ps[tid]);
}
interval:s:'"$DURP"' {
    print(@poll_avg_ns);
    print(@poll_cnt);
    exit();
}'

wait "$LOAD" 2>/dev/null
pkill -f 'iperf3 -s' 2>/dev/null
echo "RESULT pollcost module=$MOD src=$SRC N=$N dur=$DUR streams=$STREAMS"
