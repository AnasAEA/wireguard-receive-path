#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# C_stack (E5) + Delta_complete (E3): napi_gro_receive cost + inter-completion gap.
#   @gro_ns       -- napi_gro_receive duration (per-packet stack/GRO cost)
#   @delta_ns     -- gap between consecutive decrypt completions, per CPU
#                    (per-core decrypt cadence; global rate ~= this / online cores)
# Usage:  sudo bash measure_gro.sh <stock|patched|diag> <N> [DUR] [STREAMS] [GEN]
set -uo pipefail
MOD=${1:?usage: measure_gro.sh stock|patched|diag N [DUR] [STREAMS] [GEN]}
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
kprobe:napi_gro_receive   { @gs[tid] = nsecs; }
kretprobe:napi_gro_receive /@gs[tid]/ {
    @gro_ns = hist(nsecs - @gs[tid]);
    delete(@gs[tid]);
}
kretprobe:decrypt_packet {
    if (@dl[cpu]) { @delta_ns = hist(nsecs - @dl[cpu]); }
    @dl[cpu] = nsecs;
}
interval:s:'"$DURP"' {
    print(@gro_ns);
    print(@delta_ns);
    clear(@dl);
    exit();
}'

wait "$LOAD" 2>/dev/null
pkill -f 'iperf3 -s' 2>/dev/null
echo "RESULT gro module=$MOD src=$SRC N=$N dur=$DUR streams=$STREAMS"
