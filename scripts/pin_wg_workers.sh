#!/bin/bash
# Pin all wg-crypt-wg_mp_server kworker threads to a single CPU.
# This replicates the paper's saturation condition: all decrypt work
# competes with GRO softirq on one core instead of spreading across 10.
#
# Usage: sudo bash pin_wg_workers.sh [cpu]
#   cpu: CPU number to pin to (default: 0)
#
# Run AFTER setup_multipeer.sh and BEFORE measure_multipeer.sh.
# The kernel may spawn new kworkers during traffic; re-run this script
# once traffic has started to catch them.

CPU=${1:-0}
WQ_NAME="wg-crypt-wg_mp_server"

PIDS=$(grep -rl "$WQ_NAME" /proc/[0-9]*/comm 2>/dev/null \
    | sed 's|/proc/\([0-9]*\)/comm|\1|' | tr '\n' ' ' | sed 's/ $//')

if [ -z "$PIDS" ]; then
    echo "No $WQ_NAME kworkers found. Is the multipeer tunnel up?"
    exit 1
fi

echo "Pinning $WQ_NAME workers to CPU $CPU..."
for pid in $PIDS; do
    sudo taskset -cp $CPU $pid 2>/dev/null \
        && echo "  PID $pid → CPU $CPU ($(ps -p $pid -o comm=))"
done

echo "Done. $(echo "$PIDS" | wc -w) workers pinned."
echo "Tip: re-run this script 2-3 seconds after traffic starts to catch newly spawned workers."
