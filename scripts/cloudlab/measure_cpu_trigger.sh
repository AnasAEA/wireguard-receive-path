#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# WHY is throughput flat? Per-core busy%/softirq% at each wg_trig_k, under live load.
# Loads ~/wireguard_trigger.ko once, brings up N peers + iperf servers, then for each k
# in the list: set the knob, drive load on gen, sample the dut's per-core busy% +
# softirq% mid-load, report the hottest cores + aggregate throughput. The decisive read:
#   - if the hot core stays ~100% busy at k=8 (batched) AND throughput is flat
#       => batching did NOT free it (timer overhead ate the saving) or it's delivery-bound
#   - if the hot core drops below 100% at k=8 but throughput is flat
#       => batching freed CPU but the bottleneck MOVED (gen? decrypt?) -> pivot to Design B
#   sudo bash ~/measure_cpu_trigger.sh 8 "0 8"
# Requires on gen: /tmp/genload_json.sh + ns_c* namespaces.
set -uo pipefail
N=${1:-8}
KS=${2:-0 8}
DUR=${3:-30}
STREAMS=${4:-4}
TAU_NS=${5:-5000}
GEN=${6:-gen}
KO="$HOME/wireguard_trigger.ko"

ip link del wg0 2>/dev/null || true
rmmod wireguard 2>/dev/null || true
insmod "$KO"
echo "$TAU_NS" > /sys/module/wireguard/parameters/wg_trig_tau_ns
bash "$HOME/setup_dut_peers.sh" "$N" >/dev/null
pkill -f 'iperf3 -s' 2>/dev/null; sleep 1
for i in $(seq 0 $((N-1))); do iperf3 -s -p $((5201+i)) -D; done

for k in $KS; do
  echo "$k" > /sys/module/wireguard/parameters/wg_trig_k
  echo "================ wg_trig_k=$k (tau=${TAU_NS}ns) ================"
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
        rows.append((k, 100*(1-(b[k][1]-a[k][1])/dt), 100*(b[k][2]-a[k][2])/dt))
rows.sort(key=lambda x: -x[1])
print("  top cores by busy%% (window=%ds):" % win)
for k, busy, soft in rows[:6]:
    print(f"    {k:6} busy={busy:5.1f}%  softirq={soft:5.1f}%")
PY
  wait "$LOAD" 2>/dev/null
  GBPS=$(awk '/^GBPS/{print $2}' "$GBPS_FILE"); rm -f "$GBPS_FILE"
  echo "  GBPS=${GBPS:-NA}"
done
pkill -f 'iperf3 -s' 2>/dev/null
