# Compilation and Test Guide — Patched WireGuard Module
# Target: Fedora Asahi Remix, Apple M1 Pro, Bureau 225

---

## Overview

The `linux-source/` directory in this repo is a reference copy only — no build
infrastructure. All compilation and testing happens on the Fedora machine at
bureau 225. This guide walks through every step from a clean state to
measured results.

---

## Step 1 — Check the running kernel

```bash
uname -r
# e.g. 6.12.0-asahi-14

lsmod | grep wireguard
# confirms wireguard is a loadable module

cat /proc/config.gz | zcat | grep CONFIG_WIREGUARD
# expect: CONFIG_WIREGUARD=m
```

If `CONFIG_WIREGUARD=m` — WireGuard is a loadable module. You can rebuild
just the module without touching the full kernel. If it's `=y` (built-in),
you need to build a full kernel — see the note at the bottom.

---

## Step 2 — Install build dependencies

```bash
sudo dnf install kernel-devel-$(uname -r) gcc make git iperf3 bpftrace perf
```

Most of these are already installed from the January setup. The critical one
is `kernel-devel` — it provides the kernel headers needed to build a module
against the running kernel.

---

## Step 3 — Clone the Asahi kernel source

Fedora Asahi Remix uses the Asahi Linux kernel fork, not mainline. The source
must match the running kernel exactly.

```bash
git clone https://github.com/AsahiLinux/linux.git --depth=1 -b asahi
cd linux
```

`--depth=1` skips the full git history (~1 GB instead of ~4 GB). Takes a few
minutes depending on network speed.

---

## Step 4 — Apply the diff

Edit `drivers/net/wireguard/queueing.h`. Find `wg_queue_enqueue_per_peer_rx`
(around line 188) and apply the following change:

```diff
 static inline void wg_queue_enqueue_per_peer_rx(struct sk_buff *skb,
                                                  enum packet_state state)
 {
        struct wg_peer *peer = wg_peer_get(PACKET_PEER(skb));
+       struct sk_buff *tail;

        atomic_set_release(&PACKET_CB(skb)->state, state);
-       napi_schedule(&peer->napi);
+
+       tail = READ_ONCE(peer->rx_queue.tail);
+       if (tail == (struct sk_buff *)&peer->rx_queue.empty ||
+           atomic_read(&PACKET_CB(tail)->state) != PACKET_STATE_UNCRYPTED)
+               napi_schedule(&peer->napi);
+
        wg_peer_put(peer);
 }
```

Verify the change looks right before building:

```bash
grep -n "READ_ONCE\|rx_queue.tail\|UNCRYPTED" drivers/net/wireguard/queueing.h
```

---

## Step 5 — Configure and build the module

```bash
# Copy the running kernel's config
cp /boot/config-$(uname -r) .config
make olddefconfig

# Build only the WireGuard module (~1–2 minutes)
make -j$(nproc) M=drivers/net/wireguard
```

Output: `drivers/net/wireguard/wireguard.ko`

If the build fails with missing symbols or include errors, check that
`kernel-devel-$(uname -r)` is installed and that the Asahi branch matches
the running kernel version.

---

## Step 6 — Load the patched module

```bash
# Remove the running module
sudo modprobe -r wireguard

# Load the patched version
sudo insmod drivers/net/wireguard/wireguard.ko

# Verify
lsmod | grep wireguard
dmesg | tail -10
```

`dmesg` should show the module loading without errors. The version string
will not change — you can add a `printk` to confirm the patched version is
running if needed:

```c
// Optional: add inside wg_queue_enqueue_per_peer_rx for confirmation
pr_info_once("wireguard: patched napi_schedule active\n");
```

---

## Step 7 — Set up the WireGuard tunnel (two network namespaces)

This creates a loopback WireGuard tunnel on a single machine — sufficient
for measuring the fix without needing a second physical machine.

```bash
# Generate keys for both ends
wg genkey | tee ns1_priv | wg pubkey > ns1_pub
wg genkey | tee ns2_priv | wg pubkey > ns2_pub

# Create namespaces
sudo ip netns add ns1
sudo ip netns add ns2

# Create WireGuard interfaces
sudo ip link add wg1 type wireguard
sudo ip link add wg2 type wireguard

# Move interfaces into namespaces
sudo ip link set wg1 netns ns1
sudo ip link set wg2 netns ns2

# Configure ns1 (client side, listens on port 51820)
sudo ip netns exec ns1 wg set wg1 \
    private-key <(cat ns1_priv) \
    listen-port 51820 \
    peer $(cat ns2_pub) allowed-ips 10.0.0.2/32 endpoint 127.0.0.1:51821
sudo ip netns exec ns1 ip addr add 10.0.0.1/24 dev wg1
sudo ip netns exec ns1 ip link set wg1 up

# Configure ns2 (server side, listens on port 51821)
sudo ip netns exec ns2 wg set wg2 \
    private-key <(cat ns2_priv) \
    listen-port 51821 \
    peer $(cat ns1_pub) allowed-ips 10.0.0.1/32 endpoint 127.0.0.1:51820
sudo ip netns exec ns2 ip addr add 10.0.0.2/24 dev wg2
sudo ip netns exec ns2 ip link set wg2 up

# Test connectivity
sudo ip netns exec ns1 ping -c 3 10.0.0.2
```

---

## Step 8 — Baseline measurement (unpatched)

Run this **before** loading the patched module, on the stock WireGuard.

```bash
# Terminal 1: iperf3 server in ns2
sudo ip netns exec ns2 iperf3 -s

# Terminal 2: iperf3 client from ns1 — 8 parallel streams, 60 seconds
sudo ip netns exec ns1 iperf3 -c 10.0.0.2 -t 60 -P 8

# Terminal 3: count wasted GRO polls (work_done = 0)
sudo bpftrace -e '
  kretprobe:wg_packet_rx_poll /retval == 0/ { @wasted = count(); }
  interval:s:1 { print(@wasted); clear(@wasted); }
'

# Terminal 4: per-core CPU utilization
mpstat -P ALL 1

# Terminal 5: napi_schedule call frequency
sudo bpftrace -e '
  kprobe:napi_schedule { @calls = count(); }
  interval:s:1 { print(@calls); clear(@calls); }
'
```

Record: throughput (Gbps), latency p50/p99 (add `-J` to iperf3 for JSON
output), wasted GRO polls per second, CPU utilization on the busiest core.

---

## Step 9 — Patched measurement

Swap the module and repeat the exact same measurements.

```bash
# Tear down the tunnel first
sudo ip netns exec ns1 ip link set wg1 down
sudo ip netns exec ns2 ip link set wg2 down
sudo ip netns del ns1
sudo ip netns del ns2

# Swap module
sudo modprobe -r wireguard
sudo insmod drivers/net/wireguard/wireguard.ko

# Recreate tunnel (repeat Step 7)
# Then repeat Step 8 measurements
```

---

## Step 10 — Paper's fix (optional, if time allows)

The paper's fix moves `napi_schedule` to a dedicated workqueue. Rough
implementation target in `queueing.h` / `device.c`:

1. Add a `gro_wq` workqueue to `struct wg_device` (`device.h`)
2. Add a `rx_work` work item to `struct wg_peer` (`peer.h`)
3. In `wg_queue_enqueue_per_peer_rx`: replace `napi_schedule` with
   `queue_work_on(cpu, wg->gro_wq, &peer->rx_work)`
4. The work item calls `napi_schedule` from workqueue context

This is more invasive than the 6-line fix — track as a stretch goal.

---

## Measurement log template

Fill this in after each run.

| Config | Throughput (Gbps) | Latency p50 (ms) | Latency p99 (ms) | CPU max (%) | Wasted GRO/s |
|---|---|---|---|---|---|
| Baseline (unpatched) | | | | | |
| André's fix | | | | | |
| Paper's fix | | | | | |

---

## Troubleshooting

**Module fails to load (symbol mismatch):**
The Asahi branch may not match the running kernel exactly. Check:
```bash
modinfo drivers/net/wireguard/wireguard.ko | grep vermagic
uname -r
```
These must match. If not, checkout the exact commit matching your kernel.

**Build fails with include errors:**
```bash
sudo dnf reinstall kernel-devel-$(uname -r)
```

**Namespace ping fails:**
Check that the keys and endpoints are correct:
```bash
sudo ip netns exec ns1 wg show
sudo ip netns exec ns2 wg show
```

**WireGuard already built-in (`CONFIG_WIREGUARD=y`):**
You cannot load a module — you need to build a full custom kernel. This
adds 20–40 minutes of build time on M1. Steps:
```bash
make -j$(nproc)                    # full kernel
sudo make modules_install
sudo make install
sudo grubby --set-default /boot/vmlinuz-<new-version>
sudo reboot
```
Only pursue this if the module path is blocked.
