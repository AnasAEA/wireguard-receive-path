#!/bin/bash
# GEN-side load driver: fire one iperf3 client per client namespace at the DUT.
# Run on the GEN node (invoked over ssh by the DUT measure harness).
# Usage: bash genload.sh N DUR STREAMS
N=$1; DUR=$2; STREAMS=$3
for i in $(seq 0 $((N-1))); do
    ip netns exec "ns_c$i" iperf3 -c 10.0.0.1 \
        -p $((5201+i)) -t "$DUR" -P "$STREAMS" >/dev/null 2>&1 &
done
wait
