#!/bin/bash
# Set up multi-peer WireGuard test environment.
# Creates 1 server namespace + N client namespaces, all sharing one server WG interface.
# This replicates the paper's "many clients → one server" concurrency conditions.
#
# Usage: sudo bash setup_multipeer.sh [N]
#   N: number of client peers (default 8, should match or exceed CPU count)
#
# IP scheme:
#   Server WG:   10.99.0.1/16  (ns_mp_server, wg0, port 51830)
#   Client i WG: 10.99.<i+1>.1/16  (ns_mp_client_<i>, wg0)

set -e
N=${1:-8}
KEYS_DIR="$(dirname "$0")/keys/multipeer"
SERVER_PORT=51830

echo "Setting up multi-peer environment: 1 server + $N clients"

# ── Key generation ────────────────────────────────────────────────────────────
mkdir -p "$KEYS_DIR"

# Server keypair
if [ ! -f "$KEYS_DIR/server_priv" ]; then
    wg genkey | tee "$KEYS_DIR/server_priv" | wg pubkey > "$KEYS_DIR/server_pub"
fi
SERVER_PUB=$(cat "$KEYS_DIR/server_pub")

# Client keypairs
for i in $(seq 0 $((N-1))); do
    if [ ! -f "$KEYS_DIR/client_${i}_priv" ]; then
        wg genkey | tee "$KEYS_DIR/client_${i}_priv" | wg pubkey > "$KEYS_DIR/client_${i}_pub"
    fi
done

# ── Tear down any leftover state ──────────────────────────────────────────────
sudo ip netns del ns_mp_server 2>/dev/null || true
for i in $(seq 0 $((N-1))); do
    sudo ip netns del ns_mp_client_${i} 2>/dev/null || true
done

# ── Server namespace ──────────────────────────────────────────────────────────
echo "Creating server namespace..."
sudo ip netns add ns_mp_server
sudo ip link add wg_mp_server type wireguard
sudo ip link set wg_mp_server netns ns_mp_server

# Build wg set command with all N peers
WG_CMD="sudo ip netns exec ns_mp_server wg set wg_mp_server private-key $KEYS_DIR/server_priv listen-port $SERVER_PORT"
for i in $(seq 0 $((N-1))); do
    CLIENT_PUB=$(cat "$KEYS_DIR/client_${i}_pub")
    CLIENT_IP="10.99.$((i+1)).1"
    WG_CMD="$WG_CMD peer $CLIENT_PUB allowed-ips ${CLIENT_IP}/32"
done
eval "$WG_CMD"

sudo ip netns exec ns_mp_server ip addr add 10.99.0.1/16 dev wg_mp_server
sudo ip netns exec ns_mp_server ip link set wg_mp_server up

# ── Client namespaces ─────────────────────────────────────────────────────────
for i in $(seq 0 $((N-1))); do
    CLIENT_IP="10.99.$((i+1)).1"
    CLIENT_PRIV="$KEYS_DIR/client_${i}_priv"
    CLIENT_PORT=$((51831 + i))

    echo "Creating client $i ($CLIENT_IP)..."
    sudo ip netns add ns_mp_client_${i}
    sudo ip link add wg_mp_client_${i} type wireguard
    sudo ip link set wg_mp_client_${i} netns ns_mp_client_${i}

    sudo ip netns exec ns_mp_client_${i} wg set wg_mp_client_${i} \
        private-key "$CLIENT_PRIV" \
        listen-port $CLIENT_PORT \
        peer "$SERVER_PUB" \
            allowed-ips 10.99.0.0/16 \
            endpoint 127.0.0.1:$SERVER_PORT

    sudo ip netns exec ns_mp_client_${i} ip addr add ${CLIENT_IP}/16 dev wg_mp_client_${i}
    sudo ip netns exec ns_mp_client_${i} ip link set wg_mp_client_${i} up
done

# ── Connectivity check ────────────────────────────────────────────────────────
echo "Testing connectivity (client 0 → server)..."
sudo ip netns exec ns_mp_client_0 ping -c 2 -q 10.99.0.1

echo ""
echo "Multi-peer tunnel up: $N clients → ns_mp_server (10.99.0.1)"
echo "Server WG interface: wg_mp_server"
echo "Run: sudo bash scripts/measure_multipeer.sh [label] [$N]"
