#!/bin/bash
# Set up two-namespace WireGuard tunnel for measurement
# Keys are read from scripts/keys/
set -e

KEYS_DIR="$(dirname "$0")/keys"

NS1_PRIV="$KEYS_DIR/ns1_priv"
NS2_PRIV="$KEYS_DIR/ns2_priv"
NS1_PUB=$(cat "$KEYS_DIR/ns1_pub")
NS2_PUB=$(cat "$KEYS_DIR/ns2_pub")

# Clean up any leftover state
sudo ip netns del ns1 2>/dev/null || true
sudo ip netns del ns2 2>/dev/null || true

echo "Creating namespaces and interfaces..."
sudo ip netns add ns1
sudo ip netns add ns2
sudo ip link add wg1 type wireguard
sudo ip link add wg2 type wireguard
sudo ip link set wg1 netns ns1
sudo ip link set wg2 netns ns2

echo "Configuring ns1 (10.0.0.1, port 51820)..."
sudo ip netns exec ns1 wg set wg1 \
    private-key "$NS1_PRIV" \
    listen-port 51820 \
    peer "$NS2_PUB" allowed-ips 10.0.0.2/32 endpoint 127.0.0.1:51821
sudo ip netns exec ns1 ip addr add 10.0.0.1/24 dev wg1
sudo ip netns exec ns1 ip link set wg1 up

echo "Configuring ns2 (10.0.0.2, port 51821)..."
sudo ip netns exec ns2 wg set wg2 \
    private-key "$NS2_PRIV" \
    listen-port 51821 \
    peer "$NS1_PUB" allowed-ips 10.0.0.1/32 endpoint 127.0.0.1:51820
sudo ip netns exec ns2 ip addr add 10.0.0.2/24 dev wg2
sudo ip netns exec ns2 ip link set wg2 up

echo "Testing connectivity..."
sudo ip netns exec ns1 ping -c 2 -q 10.0.0.2
echo "Tunnel up."
