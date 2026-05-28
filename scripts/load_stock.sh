#!/bin/bash
# Load the stock (unmodified) WireGuard module
set -e

if lsmod | grep -q wireguard; then
    sudo rmmod wireguard
fi

echo "Loading stock wireguard module..."
sudo modprobe wireguard

echo "Loaded: $(lsmod | grep wireguard | head -1)"
