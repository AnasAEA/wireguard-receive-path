#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# Measure the RE-POLL GAP: time from a poll's END (the napi_complete_done MISSED
# reschedule) to the SAME napi's NEXT poll START. Split by the re-poll's outcome
# (wasted = head still UNCRYPTED, vs useful = head crypted in the gap) and gated
# on whether the previous poll actually rescheduled via MISSED.
#
# Claim under test (TRIGGER_DESIGN/MISSED_REPOLL_PROOF): the MISSED re-poll fires
# sub-us after the poll proved the head UNCRYPTED, while T_decrypt ~5us, so it is
# structurally too early => wasted. This run gives the gap distribution that
# (a) tests "sub-us", (b) explains the 44% productive reschedules, (c) calibrates tau.
#
# Polls serialize per napi (SCHED invariant), so we key timestamps by the napi ptr.
# napi_complete_done is EXPORT_SYMBOL on 5.15 -> directly kretprobe-able.
set -uo pipefail
MOD=${1:?usage: measure_repoll_gap.sh stock N [DUR] [STREAMS] [GEN]}
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
for i in $(seq 0 $((N-1))); do iperf3 -s -p $((5201+i)) -D; done
ssh -o StrictHostKeyChecking=no "$GEN" "bash /tmp/genload.sh $N $DUR $STREAMS" &
LOAD=$!
DURP=$((DUR+3))
bpftrace -e '
kprobe:wg_packet_rx_poll {
    $n = arg0;
    @napi[tid] = $n;
    @resched_seen[tid] = 0;
    if (@last_end[$n]) {
        @gap[tid] = nsecs - @last_end[$n];
        @was_repoll[tid] = @prev_resched[$n];   /* prev poll on this napi rescheduled? */
    } else {
        @gap[tid] = 0;
        @was_repoll[tid] = 0;
    }
}
kretprobe:napi_complete_done /@napi[tid]/ {
    @resched_seen[tid] = (retval == 0);          /* false => MISSED forced a reschedule */
}
kretprobe:wg_packet_rx_poll {
    $n = @napi[tid];
    if (@gap[tid]) {
        @gap_all_ns = hist(@gap[tid]);
        if (@was_repoll[tid]) {                  /* this poll IS a MISSED re-poll */
            if (retval == 0) { @missed_repoll_WASTED_ns = hist(@gap[tid]); }
            else             { @missed_repoll_useful_ns = hist(@gap[tid]); }
        }
    }
    @prev_resched[$n] = @resched_seen[tid];
    @last_end[$n] = nsecs;
    delete(@napi[tid]); delete(@gap[tid]);
    delete(@was_repoll[tid]); delete(@resched_seen[tid]);
}
interval:s:'"$DURP"' {
    print(@gap_all_ns);
    print(@missed_repoll_WASTED_ns);
    print(@missed_repoll_useful_ns);
    clear(@last_end); clear(@prev_resched);
    exit();
}'
wait "$LOAD" 2>/dev/null
pkill -f 'iperf3 -s' 2>/dev/null
echo "RESULT repoll_gap module=$MOD src=$SRC N=$N dur=$DUR streams=$STREAMS"
