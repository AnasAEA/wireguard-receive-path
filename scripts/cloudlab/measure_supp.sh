#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# MISSED RE-POLL SUPPRESSION A/B (single binary). The simplest intervention: at the
# poll-completion site, if the head is still UNCRYPTED, clear NAPI_STATE_MISSED so the
# kernel parks the NAPI instead of firing a wasted re-poll (the head's own decrypt
# completion re-wakes a productive poll). Loads ~/wireguard_trigger.ko ONCE with the
# coalescing trigger OFF (wg_trig_k=0), then sweeps wg_supp in {0,1}: 0 = stock, 1 =
# suppress. Same binary, same load/probes as the baselines, so the ONLY variable is
# the suppression. Per (supp,run) captures throughput (genload_json on gen) + wasted
# fraction (bpftrace on dut).
#   sudo bash ~/measure_supp.sh 8 7
# Emits CSV,module,peers,run,gbps,wasted,useful,wasted_frac,src  (module = "supp0/1")
# then a delta-vs-supp0 summary. Watch for stalls: if GBPS collapses at supp=1 the
# lost-wakeup corner case bit us and we add the timer backstop. Requires on gen:
# /tmp/genload_json.sh + ns_c* namespaces.
set -uo pipefail
N=${1:-8}
RUNS=${2:-7}
DUR=${3:-20}
STREAMS=${4:-4}
GEN=${5:-gen}
KO="$HOME/wireguard_trigger.ko"
CSV="$HOME/supp_$(date +%Y%m%d_%H%M).csv"

ip link del wg0 2>/dev/null || true
rmmod wireguard 2>/dev/null || true
insmod "$KO"
echo 0 > /sys/module/wireguard/parameters/wg_trig_k   # isolate wg_supp: coalescer OFF
bash "$HOME/setup_dut_peers.sh" "$N" >/dev/null
SRC=$(cat /sys/module/wireguard/srcversion)
pkill -f 'iperf3 -s' 2>/dev/null; sleep 1
for i in $(seq 0 $((N-1))); do iperf3 -s -p $((5201+i)) -D; done

echo "module,peers,run,gbps,wasted,useful,wasted_frac,src" > "$CSV"
DURP=$((DUR+3))
for run in $(seq 1 "$RUNS"); do
  for s in $(echo "0 1" | tr ' ' '\n' | sort -R); do
    echo "$s" > /sys/module/wireguard/parameters/wg_supp
    echo "[supp] N=$N run=$run/$RUNS wg_supp=$s" >&2
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
    echo "CSV,supp$s,$N,$run,$GBPS,$W,$U,$FRAC,$SRC"
    echo "supp$s,$N,$run,$GBPS,$W,$U,$FRAC,$SRC" >> "$CSV"
  done
done
pkill -f 'iperf3 -s' 2>/dev/null
echo "[supp] done -> $CSV" >&2

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
    gm = st.median(g[m]["gbps"]); wm = st.median(g[m]["wasted_frac"])
    print(f"{m:8}{len(g[m]['gbps']):>4}{gm:>10.3f}{cv(g[m]['gbps']):>9.1f}{wm:>11.4f}{cv(g[m]['wasted_frac']):>10.1f}")
if "supp0" in g and "supp1" in g:
    bg, bw = st.median(g["supp0"]["gbps"]), st.median(g["supp0"]["wasted_frac"])
    dg = st.median(g["supp1"]["gbps"]) - bg
    dw = st.median(g["supp1"]["wasted_frac"]) - bw
    pct = 100*dg/bg if bg else 0
    print(f"\n-- supp1 - supp0 (the headline) --")
    print(f"  dGbps={dg:+.3f} ({pct:+.1f}%)   dWastedFrac={dw:+.4f}")
PY
