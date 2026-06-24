#!/bin/bash
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# Low-variance sweep: repeats measure_run.sh over module x peers, REPEATS times each,
# into one CSV, then prints median/IQR/CV via analyze_sweep.py. Order is randomized
# within (peers) so module isn't confounded with thermal/time drift.
#   run_sweep.sh "1 8 16 32" "stock patched" 7 20 4
set -uo pipefail
PEERS=${1:-"1 8 16 32"}
MODS=${2:-"stock patched"}
REPEATS=${3:-7}
DUR=${4:-20}
STREAMS=${5:-4}
CSV=${6:-$HOME/sweep_$(date +%Y%m%d_%H%M).csv}
echo "module,peers,run,gbps,wasted,useful,wasted_frac,src" > "$CSV"
for N in $PEERS; do
    for r in $(seq 1 "$REPEATS"); do
        # shuffle module order each repeat to decorrelate from drift
        for MOD in $(echo $MODS | tr ' ' '\n' | shuf); do
            echo "[sweep] peers=$N run=$r/$REPEATS mod=$MOD"
            bash "$HOME/measure_run.sh" "$MOD" "$N" "$r" "$DUR" "$STREAMS" \
                | grep '^CSV,' | sed 's/^CSV,//' >> "$CSV"
        done
    done
done
echo "[sweep] done -> $CSV"
python3 "$HOME/analyze_sweep.py" "$CSV" || true
