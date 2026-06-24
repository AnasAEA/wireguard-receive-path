#!/bin/bash
# gen-side load driver that CAPTURES aggregate throughput.
# Runs one iperf3 client per peer namespace, each writing JSON, then sums
# end.sum_received.bits_per_second across all peers and prints "GBPS <n>".
# Runs as root (node-to-node ssh is root); needs the ns_c* namespaces from
# setup_gen_clients.sh.
N=$1; DUR=$2; STREAMS=$3
rm -f /tmp/ipf_*.json
for i in $(seq 0 $((N-1))); do
    ip netns exec "ns_c$i" iperf3 -c 10.0.0.1 -p $((5201+i)) \
        -t "$DUR" -P "$STREAMS" -J > "/tmp/ipf_$i.json" 2>/dev/null &
done
wait
python3 - <<'PY'
import json, glob
tot = 0.0
for f in glob.glob('/tmp/ipf_*.json'):
    try:
        d = json.load(open(f))
        tot += d['end']['sum_received']['bits_per_second']
    except Exception:
        pass
print("GBPS %.3f" % (tot / 1e9))
PY
