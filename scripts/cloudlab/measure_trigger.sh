#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# TRIGGER A/B (single binary). Loads ~/wireguard_trigger.ko ONCE, brings up N peers +
# iperf servers, then sweeps the wg_trig_k knob at runtime (e.g. "0 8 16"): k=0 is
# stock behaviour, k>0 enables count-or-timeout RX coalescing. Because it is the SAME
# loaded module across all k, the ONLY variable is the trigger — no base divergence,
# no reload variance. Per (k,run) captures aggregate throughput (genload_json on gen)
# and wasted-poll fraction (bpftrace on dut), same probes/load as measure_run.sh so
# numbers are comparable to the locked baselines.
#   sudo bash ~/measure_trigger.sh 8 "0 8" 7
# Emits CSV,module,peers,run,gbps,wasted,useful,wasted_frac,src  (module = "k<val>")
# then a delta-vs-k0 summary. Requires on gen: /tmp/genload_json.sh + ns_c* namespaces.
set -uo pipefail
N=${1:-8}
KS=${2:-0 8}
RUNS=${3:-7}
TAU_NS=${4:-5000}
DUR=${5:-20}
STREAMS=${6:-4}
GEN=${7:-gen}
KO="$HOME/wireguard_trigger.ko"
CSV="$HOME/trigger_$(date +%Y%m%d_%H%M).csv"

# --- load the single trigger binary once, bring up peers + iperf servers once ---
ip link del wg0 2>/dev/null || true
rmmod wireguard 2>/dev/null || true
insmod "$KO"
echo "$TAU_NS" > /sys/module/wireguard/parameters/wg_trig_tau_ns
bash "$HOME/setup_dut_peers.sh" "$N" >/dev/null
SRC=$(cat /sys/module/wireguard/srcversion)
pkill -f 'iperf3 -s' 2>/dev/null; sleep 1
for i in $(seq 0 $((N-1))); do iperf3 -s -p $((5201+i)) -D; done

echo "module,peers,run,gbps,wasted,useful,wasted_frac,src" > "$CSV"
DURP=$((DUR+3))
for run in $(seq 1 "$RUNS"); do
  # shuffle k order each round so any slow drift can't bias one setting
  for k in $(echo $KS | tr ' ' '\n' | sort -R); do
    echo "$k" > /sys/module/wireguard/parameters/wg_trig_k
    echo "[trig] N=$N run=$run/$RUNS k=$k tau=${TAU_NS}ns" >&2
    GBPS_FILE=$(mktemp)
    ssh -o StrictHostKeyChecking=no "$GEN" "bash /tmp/genload_json.sh $N $DUR $STREAMS" > "$GBPS_FILE" 2>/dev/null &
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
    echo "CSV,k$k,$N,$run,$GBPS,$W,$U,$FRAC,$SRC"
    echo "k$k,$N,$run,$GBPS,$W,$U,$FRAC,$SRC" >> "$CSV"
  done
done
pkill -f 'iperf3 -s' 2>/dev/null
echo "[trig] done -> $CSV" >&2

# --- summary: median per k + delta vs k0 ---
python3 - "$CSV" <<'PY'
import sys, csv, statistics as st
from collections import defaultdict
g = defaultdict(lambda: defaultdict(list))
for r in csv.DictReader(open(sys.argv[1])):
    for m in ("gbps", "wasted_frac"):
        try: g[r["module"]][m].append(float(r[m]))
        except: pass
def cv(xs): return st.pstdev(xs)/st.mean(xs)*100 if len(xs)>1 and st.mean(xs) else 0.0
print(f"\n{'k':8}{'n':>4}{'gbps_med':>10}{'gbps_cv%':>9}{'wfrac_med':>11}{'wfrac_cv%':>10}")
def kval(m): return int(m[1:]) if m[1:].isdigit() else 0
order = sorted(g, key=kval)
for m in order:
    gm = st.median(g[m]["gbps"]); wm = st.median(g[m]["wasted_frac"])
    print(f"{m:8}{len(g[m]['gbps']):>4}{gm:>10.3f}{cv(g[m]['gbps']):>9.1f}{wm:>11.4f}{cv(g[m]['wasted_frac']):>10.1f}")
base = "k0"
if base in g:
    bg, bw = st.median(g[base]["gbps"]), st.median(g[base]["wasted_frac"])
    print(f"\n-- median(k) - median(k0):  k0 = {bg:.3f} Gb/s, wfrac {bw:.4f} --")
    for m in order:
        if m == base: continue
        dg = st.median(g[m]["gbps"]) - bg
        dw = st.median(g[m]["wasted_frac"]) - bw
        pct = 100*dg/bg if bg else 0
        print(f"{m:>6}: dGbps={dg:+.3f} ({pct:+.1f}%)  dWastedFrac={dw:+.4f}")
PY
