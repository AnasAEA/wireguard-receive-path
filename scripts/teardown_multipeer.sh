#!/bin/bash
# Tear down multi-peer WireGuard environment.
# Usage: sudo bash teardown_multipeer.sh [N]
N=${1:-8}

ip netns del ns_mp_server 2>/dev/null || true
for i in $(seq 0 $((N-1))); do
    ip netns del ns_mp_client_${i} 2>/dev/null || true
done
echo "Multi-peer tunnel torn down."
