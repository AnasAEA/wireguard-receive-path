#!/bin/bash
# Create N WireGuard client peers as network namespaces on the GEN node, all
# targeting the DUT receiver over the real 10G link (CloudLab WG testbed).
#
# Each client wg interface is created in the ROOT namespace (so its *encrypted*
# UDP egresses the physical NIC toward the DUT) and then moved into its own
# netns. The app (iperf3/ping) runs inside the netns and sends plaintext to the
# DUT tunnel IP; WireGuard encrypts and ships it from the root ns. This is the
# standard wg namespace trick and is what gives us N independent peers => N napi
# contexts => real multi-core decrypt concurrency (the EoI condition).
#
# Usage:  sudo bash setup_gen_clients.sh N [DUT_PUB] [DUT_LINK_IP]
#   N            number of client peers
#   DUT_PUB      DUT wg public key   (default: instance #1 key)
#   DUT_LINK_IP  DUT physical link IP (default: 192.168.1.1)
#
# IP scheme: client i tunnel IP = 10.0.<i+1>.1/16 ; DUT tunnel IP = 10.0.0.1/16.
set -euo pipefail

N=${1:?usage: setup_gen_clients.sh N [DUT_PUB] [DUT_LINK_IP]}
DUT_PUB=${2:-8+ROmIIc9bFQ74dzb9nmENZ/7vxW3RUcmv5tOOIA2j8=}
DUT_IP=${3:-192.168.1.1}
PORT=51820
KEYS=/tmp/wg_clients          # fixed absolute path (avoids sudo $HOME ambiguity)
mkdir -p "$KEYS"

echo "[gen] setting up $N client namespaces -> DUT $DUT_IP:$PORT"

# tear down any previous client namespaces
for ns in $(ip netns list 2>/dev/null | awk '/^ns_c[0-9]/{print $1}'); do
    ip netns del "$ns" 2>/dev/null || true
done

: > "$KEYS/client_pubs.txt"
for i in $(seq 0 $((N-1))); do
    [ -f "$KEYS/c${i}.key" ] || wg genkey > "$KEYS/c${i}.key"
    PUB=$(wg pubkey < "$KEYS/c${i}.key")
    echo "$i $PUB 10.0.$((i+1)).1" >> "$KEYS/client_pubs.txt"

    ns=ns_c${i}; ifc=wgc${i}
    ip netns add "$ns"
    ip link add "$ifc" type wireguard           # created in ROOT ns -> UDP egresses phys NIC
    ip link set "$ifc" netns "$ns"
    ip netns exec "$ns" wg set "$ifc" private-key "$KEYS/c${i}.key" \
        peer "$DUT_PUB" allowed-ips 10.0.0.0/16 endpoint "$DUT_IP:$PORT"
    ip netns exec "$ns" ip addr add 10.0.$((i+1)).1/16 dev "$ifc"
    ip netns exec "$ns" ip link set "$ifc" up
    ip netns exec "$ns" ip link set lo up
done

echo "[gen] created $N clients. Pubkeys -> $KEYS/client_pubs.txt"
echo "[gen] next: on DUT run setup_dut_peers.sh $N (it scp's this pubs file)"
