#!/bin/bash
# Trace context switches and CPU migrations for WireGuard kworker threads.
# Collects per-thread counts over a fixed interval, then prints a summary.
#
# Usage: sudo bash trace_ctx_switches.sh [duration_seconds]
#   duration: how long to trace (default: 30)
#
# Requires: bpftrace >= 0.12, wireguard tunnel up and passing traffic

DURATION=${1:-30}
WQ_NAME="wg-crypt"

# Collect target PIDs
PIDS=$(ps -eo pid,comm | awk -v wq="$WQ_NAME" '$2 ~ wq {print $1}')
if [ -z "$PIDS" ]; then
    echo "No $WQ_NAME kworkers found. Is the tunnel up?"
    exit 1
fi

echo "Tracing WireGuard kworker context switches / migrations for ${DURATION}s..."
echo "PIDs: $PIDS"
echo ""

# Build a bpftrace pid filter expression: pid == A || pid == B || ...
PID_FILTER=$(echo $PIDS | tr ' ' '\n' | awk '{printf "pid == %s || ", $1}' | sed 's/ || $//')

sudo bpftrace -e "
  software:cpu-migrations:1
  / $PID_FILTER /
  { @migrations[comm] = count(); }

  software:context-switches:1
  / $PID_FILTER /
  { @ctx_switches[comm] = count(); }

  interval:s:$DURATION { exit(); }
"
