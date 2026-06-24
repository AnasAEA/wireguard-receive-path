#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# MECHANISM CHECK in the SPREAD (sdfn) regime. Classifies every wg_packet_rx_poll by what
# preceded it on the same peer NAPI:
#   - the previous napi_complete_done RESCHEDULED (returned false) => this poll is a
#     MISSED re-poll;
#   - it PARKED (returned true)                                   => this poll is a fresh wake.
# Then splits wasted polls (retval==0) into missed-re-poll vs fresh. Answers:
#   Q2: in this parallel config, are wasted polls still dominated by MISSED re-polls?
#   Q1: does `move` (wg_supp, the re-poll-site fix) actually fire — i.e. convert
#       reschedules into parks and cut the MISSED re-polls?
# Run per condition under load.  sudo bash ~/measure_missed.sh 8 15
set -uo pipefail
N=${1:-8}; DUR=${2:-15}; STREAMS=${3:-4}; GEN=${4:-gen}; NIC=${5:-enp6s0f1}
KO="$HOME/wireguard_trigger.ko"; GUARD=$((DUR+15))

set_cond() { local s=0 k=0 h=0
  case "$1" in move) s=1 ;; batch) k=8 ;; root) h=1 ;; esac
  echo $s >/sys/module/wireguard/parameters/wg_supp
  echo $k >/sys/module/wireguard/parameters/wg_trig_k
  echo $h >/sys/module/wireguard/parameters/wg_headwake; }

ip link del wg0 2>/dev/null||true; rmmod wireguard 2>/dev/null||true
insmod "$KO"; echo 5000 >/sys/module/wireguard/parameters/wg_trig_tau_ns
ethtool -N "$NIC" rx-flow-hash udp4 sdfn >/dev/null 2>&1
bash "$HOME/setup_dut_peers.sh" "$N" >/dev/null
pkill -f 'iperf3 -s' 2>/dev/null; sleep 1
for i in $(seq 0 $((N-1))); do iperf3 -s -p $((5201+i)) -D; done

read -r -d '' BT <<'BPF' || true
kprobe:napi_complete_done { @ncd[cpu] = arg0; }
kretprobe:napi_complete_done {
    $n = @ncd[cpu];
    if ($n != 0) {
        @rstate[$n] = retval + 1;          /* 1 = rescheduled (MISSED), 2 = parked */
        if (retval == 0) { @ncd_resched++; }
    }
}
kprobe:wg_packet_rx_poll { @es[cpu] = @rstate[arg0]; }
kretprobe:wg_packet_rx_poll {
    @polls++;
    $s = @es[cpu];
    if ($s == 1) { @repolls_missed++; }
    if (retval == 0) {
        @wasted++;
        if      ($s == 1) { @wasted_missed++; }
        else if ($s == 2) { @wasted_fresh++; }
        else              { @wasted_unknown++; }
    }
}
interval:s:DURSEC {
    printf("RESULT polls=%llu wasted=%llu wasted_missed=%llu wasted_fresh=%llu wasted_unknown=%llu repolls_missed=%llu ncd_resched=%llu\n",
           @polls, @wasted, @wasted_missed, @wasted_fresh, @wasted_unknown, @repolls_missed, @ncd_resched);
    clear(@polls); clear(@wasted); clear(@wasted_missed); clear(@wasted_fresh);
    clear(@wasted_unknown); clear(@repolls_missed); clear(@ncd_resched);
    exit();
}
BPF
BT=${BT//DURSEC/$DUR}

for cond in stock move root; do
  set_cond "$cond"
  echo "================ cond=$cond (sdfn) ================"
  timeout "$GUARD" ssh -o StrictHostKeyChecking=no "$GEN" "bash /tmp/genload_json.sh $N $DUR $STREAMS" >/dev/null 2>&1 &
  sleep 3
  OUT=$(bpftrace -e "$BT" 2>/dev/null | grep '^RESULT')
  wait 2>/dev/null
  echo "$OUT" | awk '{
    for(i=1;i<=NF;i++){split($i,a,"="); v[a[1]]=a[2]}
    w=v["wasted"]+0; wm=v["wasted_missed"]+0; wf=v["wasted_fresh"]+0;
    printf "  polls=%d  wasted=%d (%.1f%% of polls)\n", v["polls"], w, (v["polls"]>0? 100*w/v["polls"]:0);
    printf "  of wasted: MISSED re-poll=%d (%.1f%%)  fresh-wake=%d (%.1f%%)  unknown=%d\n",
           wm, (w>0?100*wm/w:0), wf, (w>0?100*wf/w:0), v["wasted_unknown"];
    printf "  total MISSED re-polls (any outcome)=%d  napi reschedules(all napi)=%d\n",
           v["repolls_missed"], v["ncd_resched"];
  }'
done
ethtool -N "$NIC" rx-flow-hash udp4 sd >/dev/null 2>&1
pkill -f 'iperf3 -s' 2>/dev/null
echo "[missed] hash reverted to sd."
