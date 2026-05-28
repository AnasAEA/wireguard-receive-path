#!/bin/bash
# Restore all wg-crypt-wg_mp_server kworker threads to the full CPU mask.
# Run after a pinned experiment to return to normal scheduling.
#
# Usage: sudo bash unpin_wg_workers.sh

WQ_NAME="wg-crypt-wg_mp_server"
NPROC=$(nproc)
FULL_MASK=$(python3 -c "print(hex((1 << $NPROC) - 1))")

PIDS=$(ps -eo pid,comm | awk -v wq="$WQ_NAME" '$2 ~ wq {print $1}')

if [ -z "$PIDS" ]; then
    echo "No $WQ_NAME kworkers found."
    exit 0
fi

echo "Restoring $WQ_NAME workers to all $NPROC CPUs (mask $FULL_MASK)..."
for pid in $PIDS; do
    sudo taskset -p "$FULL_MASK" $pid 2>/dev/null \
        && echo "  PID $pid → all CPUs ($(ps -p $pid -o comm=))"
done

echo "Done."
