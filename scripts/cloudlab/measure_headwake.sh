#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# HEAD-GATED WAKE A/B (single binary). The root fix: wake the RX poll only when a
# decrypt completion makes the head deliverable (completes the packet the poll parked
# on, or the queue was empty). Loads ~/wireguard_trigger.ko ONCE with the other levers
# OFF (wg_trig_k=0, wg_supp=0), then sweeps wg_headwake in {0,1}: 0 = stock, 1 = head-
# gated. Same binary, same load/probes as the baselines. The gen load is wrapped in a
# hard `timeout` so a stall (if the head-gate strands packets) can't hang the harness —
# a stalled run shows GBPS=NA / 0 instead of blocking.
#   sudo bash ~/measure_headwake.sh 8 7
# Emits CSV,module,peers,run,gbps,wasted,useful,wasted_frac,src  (module = "hw0/1")
set -uo pipefail
N=${1:-8}
RUNS=${2:-7}
DUR=${3:-20}
STREAMS=${4:-4}
GEN=${5:-gen}
KO="$HOME/wireguard_trigger.ko"
CSV="$HOME/headwake_$(date +%Y%m%d_%H%M).csv"

ip link del wg0 2>/dev/null || true
rmmod wireguard 2>/dev/null || true
insmod "$KO"
echo 0 > /sys/module/wireguard/parameters/wg_trig_k
echo 0 > /sys/module/wireguard/parameters/wg_supp
bash "$HOME/setup_dut_peers.sh" "$N" >/dev/null
SRC=$(cat /sys/module/wireguard/srcversion)
pkill -f 'iperf3 -s' 2>/dev/null; sleep 1
for i in $(seq 0 $((N-1))); do iperf3 -s -p $((5201+i)) -D; done

echo "module,peers,run,gbps,wasted,useful,wasted_frac,src" > "$CSV"
DURP=$((DUR+3))
GUARD=$((DUR+15))   # hard cap on the gen load so a stall can't hang us
for run in $(seq 1 "$RUNS"); do
  for h in $(echo "0 1" | tr ' ' '\n' | sort -R); do
    echo "$h" > /sys/module/wireguard/parameters/wg_headwake
    echo "[hw] N=$N run=$run/$RUNS wg_headwake=$h" >&2
    GBPS_FILE=$(mktemp)
    timeout "$GUARD" ssh -o StrictHostKeyChecking=no "$GEN" \
        "bash /tmp/genload_json.sh $N $DUR $STREAMS" > "$GBPS_FILE" 2>/dev/null &
    LOAD=$!
    OUT=$(bpftrace -e '
      kretprobe:wg_packet_rx_poll /retval==0/ { @w += 1; }
      kretprobe:wg_packet_rx_poll /retval>0/  { @u += 1; }
      interval:s:'"$DURP"' { printf("WU %lld %lld\n", @w, @u); exit(); }' 2>/dev/null)
    wait "$LOAD" 2>/dev/null
    W=$(echo "$OUT" | awk '/^WU/{print $2}'); U=$(echo "$OUT" | awk '/^WU/{print $3}')
    GBPS=$(awk '/^GBPS/{print $2}' "$GBPS_FILE"); rm -f "$GBPS_FILE"
    : "${W:=0}" "${U:=0}" "${GBPS:=NA}"
    FRAC=$(awk "BEGIN{ if ($W+$U>0) printf \"%.4f\", $W/($W+$U); else print \"NA\" }")
    echo "CSV,hw$h,$N,$run,$GBPS,$W,$U,$FRAC,$SRC"
    echo "hw$h,$N,$run,$GBPS,$W,$U,$FRAC,$SRC" >> "$CSV"
  done
done
pkill -f 'iperf3 -s' 2>/dev/null
echo "[hw] done -> $CSV" >&2

python3 - "$CSV" <<'PY'
import sys, csv, statistics as st
from collections import defaultdict
g = defaultdict(lambda: defaultdict(list))
for r in csv.DictReader(open(sys.argv[1])):
    for m in ("gbps", "wasted_frac"):
        try: g[r["module"]][m].append(float(r[m]))
        except: pass
def cv(xs): return st.pstdev(xs)/st.mean(xs)*100 if len(xs)>1 and st.mean(xs) else 0.0
print(f"\n{'mode':8}{'n':>4}{'gbps_med':>10}{'gbps_cv%':>9}{'wfrac_med':>11}{'wfrac_cv%':>10}")
for m in sorted(g):
    if not g[m]["gbps"]: continue
    gm = st.median(g[m]["gbps"]); wm = st.median(g[m]["wasted_frac"]) if g[m]["wasted_frac"] else float("nan")
    print(f"{m:8}{len(g[m]['gbps']):>4}{gm:>10.3f}{cv(g[m]['gbps']):>9.1f}{wm:>11.4f}{cv(g[m]['wasted_frac']):>10.1f}")
if g["hw0"]["gbps"] and g["hw1"]["gbps"]:
    bg, bw = st.median(g["hw0"]["gbps"]), st.median(g["hw0"]["wasted_frac"])
    dg = st.median(g["hw1"]["gbps"]) - bg; dw = st.median(g["hw1"]["wasted_frac"]) - bw
    print(f"\n-- hw1 - hw0 (the headline) --\n  dGbps={dg:+.3f} ({100*dg/bg:+.1f}%)   dWastedFrac={dw:+.4f}")
PY
