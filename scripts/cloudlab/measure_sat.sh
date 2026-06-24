#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# SATURATION CHECK (self-contained). Loads $MOD, brings up N peers + iperf SERVERS on
# dut, drives load on gen, samples dut per-core busy%/softirq% mid-load, reports the
# aggregate throughput. Answers: is the receive bottleneck core saturated => CPU-bound?
#   sudo bash ~/measure_sat.sh stock 8
# Requires on gen: /tmp/genload_json.sh (throughput-capturing load) + ns_c* namespaces.
set -uo pipefail
MOD=${1:-stock}; N=${2:-8}; DUR=${3:-30}; STREAMS=${4:-4}; GEN=${5:-gen}
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
sleep 3
python3 - "$DUR" <<'PY'
import time, sys
win = max(5, int(sys.argv[1]) - 8)
def snap():
    c = {}
    for l in open('/proc/stat'):
        if l.startswith('cpu') and l[3:4].isdigit():
            p = l.split(); t = sum(map(int, p[1:])); idle = int(p[4]) + int(p[5]); soft = int(p[7])
            c[p[0]] = (t, idle, soft)
    return c
a = snap(); time.sleep(win); b = snap()
rows = []
for k in a:
    dt = b[k][0] - a[k][0]
    if dt > 0:
        rows.append((k, 100 * (1 - (b[k][1] - a[k][1]) / dt), 100 * (b[k][2] - a[k][2]) / dt))
rows.sort(key=lambda x: -x[1])
print("top cores by busy%% (window=%ds):" % win)
for k, busy, soft in rows[:8]:
    print(f"  {k:6} busy={busy:5.1f}%  softirq={soft:5.1f}%")
PY
wait "$LOAD" 2>/dev/null
pkill -f 'iperf3 -s' 2>/dev/null
GBPS=$(awk '/^GBPS/{print $2}' "$GBPS_FILE"); rm -f "$GBPS_FILE"
echo "RESULT sat module=$MOD src=$SRC N=$N dur=$DUR streams=$STREAMS GBPS=${GBPS:-NA}"
