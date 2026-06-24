#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# Cost-model probe on the DUT (Phase C). One run captures:
#   E2  T_decrypt          -- decrypt_packet latency histogram
#   E4  C_poll / C_deliver -- wg_packet_rx_poll average duration keyed by work_done
#                             (C_poll = avg dur at work_done==0; C_deliver = slope)
# Drives load from GEN over ssh.
#
# Usage:  sudo bash measure_cost.sh <stock|patched|diag> <N> [DUR] [STREAMS] [GEN]
# Needs:  ~/wireguard_<mod>.ko, ~/setup_dut_peers.sh, gen:/tmp/genload.sh
set -uo pipefail

MOD=${1:?usage: measure_cost.sh stock|patched|diag N [DUR] [STREAMS] [GEN]}
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
kprobe:decrypt_packet      { @ds[tid] = nsecs; }
kretprobe:decrypt_packet /@ds[tid]/ {
    @T_decrypt_ns = hist(nsecs - @ds[tid]);
    delete(@ds[tid]);
}
kprobe:wg_packet_rx_poll   { @ps[tid] = nsecs; }
kretprobe:wg_packet_rx_poll /@ps[tid]/ {
    $d = nsecs - @ps[tid];
    @poll_avg_ns[retval] = avg($d);
    @poll_cnt[retval]    = count();
    delete(@ps[tid]);
}
interval:s:'"$DURP"' {
    print(@T_decrypt_ns);
    print(@poll_avg_ns);
    print(@poll_cnt);
    exit();
}'

wait "$LOAD" 2>/dev/null
pkill -f 'iperf3 -s' 2>/dev/null
echo "RESULT cost module=$MOD src=$SRC N=$N dur=$DUR streams=$STREAMS"
