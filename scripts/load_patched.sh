#!/bin/bash
# Load the patched WireGuard module (André's conditional napi_schedule fix)
set -e

WKO="$(dirname "$0")/../linux/drivers/net/wireguard/wireguard.ko"

if lsmod | grep -q wireguard; then
    rmmod wireguard
fi

echo "Loading dependency modules..."
modprobe udp_tunnel ip6_udp_tunnel libcurve25519

echo "Loading patched wireguard.ko..."
insmod "$WKO"

echo "Loaded: $(lsmod | grep wireguard | head -1)"
