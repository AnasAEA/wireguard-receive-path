#!/bin/bash
# Load the stock (unmodified) WireGuard module
set -e

if lsmod | grep -q wireguard; then
    rmmod wireguard
fi

echo "Loading stock wireguard module..."
modprobe wireguard

echo "Loaded: $(lsmod | grep wireguard | head -1)"
