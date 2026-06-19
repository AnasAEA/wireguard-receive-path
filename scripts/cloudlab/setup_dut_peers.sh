#!/bin/bash
# Configure the DUT wg0 receiver with N peers (one per GEN client namespace).
# Creates a fresh wg0 in the root namespace using whatever wireguard module is
# currently loaded (the measure harness controls stock-vs-patched), so the real
# receive path is instrumentable. Reads client pubkeys from the GEN node.
#
# Usage:  sudo bash setup_dut_peers.sh N [GEN_HOST]
#   N         number of peers (must match setup_gen_clients.sh N on GEN)
#   GEN_HOST  ssh name of the gen node (default: gen)
#
# Requires: dut wg key at /etc/wireguard/dut.key (created in E0.4).
set -euo pipefail

N=${1:?usage: setup_dut_peers.sh N [GEN_HOST]}
GEN_HOST=${2:-gen}
PUBS=/tmp/client_pubs.txt       # fixed absolute path (avoids sudo $HOME ambiguity)
PORT=51820

# fetch the client pubkeys file from gen (scp). If ssh between nodes is not set
# up, copy /tmp/wg_clients/client_pubs.txt from gen to /tmp/client_pubs.txt by hand.
if [ ! -f "$PUBS" ] || [ "${REFRESH:-0}" = "1" ]; then
    scp -o StrictHostKeyChecking=no "$GEN_HOST":/tmp/wg_clients/client_pubs.txt "$PUBS"
fi

echo "[dut] (re)building wg0 with $N peers"
ip link del wg0 2>/dev/null || true
ip link add wg0 type wireguard
wg set wg0 listen-port "$PORT" private-key /etc/wireguard/dut.key
ip addr add 10.0.0.1/16 dev wg0
ip link set wg0 up

while read -r i pub ip; do
    [ -n "${pub:-}" ] || continue
    wg set wg0 peer "$pub" allowed-ips "${ip}/32"
done < <(head -n "$N" "$PUBS")

PEERS=$(wg show wg0 peers | wc -l)
echo "[dut] wg0 up at 10.0.0.1/16 with $PEERS peers (loaded module srcversion: $(cat /sys/module/wireguard/srcversion))"
