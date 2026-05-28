#!/bin/bash
# Tear down the WireGuard test tunnel
sudo ip netns exec ns1 ip link set wg1 down 2>/dev/null || true
sudo ip netns exec ns2 ip link set wg2 down 2>/dev/null || true
sudo ip netns del ns1 2>/dev/null || true
sudo ip netns del ns2 2>/dev/null || true
echo "Tunnel torn down."
