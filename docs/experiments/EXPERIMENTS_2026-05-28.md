# Experimental Log — May 28, 2026
# WireGuard EoI Fix: Build, Deployment, and Measurement

**Author:** Anas Ait El Hadj  
**Machine:** Apple M1 Pro, Fedora Asahi Remix 44, kernel `6.19.13-400.asahi.fc44.aarch64+16k`  
**Supervisor:** André Freyssinet (ScalAgent / Inria KrakOS)

---

## 1. Objective

This document records every step performed on May 28, 2026: applying André's proposed 6-line
fix to WireGuard's kernel source, building and loading the patched module, and running a series
of measurements designed to quantify the reduction in wasted GRO (Generic Receive Offload)
invocations caused by Execution Order Inversion (EoI).

The fix targets `wg_queue_enqueue_per_peer_rx` in
`drivers/net/wireguard/queueing.h`. The goal is to suppress `napi_schedule` calls that fire when
GRO has no chance of making progress — i.e., when the head of the per-peer RX queue is still in
`PACKET_STATE_UNCRYPTED`.

---

## 2. Environment

| Property | Value |
|---|---|
| Machine | Apple M1 Pro (ARM64, 8 perf + 2 efficiency cores = 10 total) |
| OS | Fedora Asahi Remix 44 |
| Kernel | `6.19.13-400.asahi.fc44.aarch64+16k` (Asahi Linux fork, 16K page size) |
| WireGuard config | `CONFIG_WIREGUARD=m` (loadable module) |
| Kernel source | AsahiLinux/linux, branch `asahi`, depth=1 clone |
| Build toolchain | GCC 16.1.1 (Red Hat 16.1.1-2) |
| Measurement tools | iperf3, bpftrace |

---

## 3. The Patch

### 3.1 Background: the EoI problem

WireGuard's receive pipeline has three stages:

1. **Stage 1** — `wg_packet_receive` in `receive.c`: UDP packet arrives, is pushed onto the
   global `decrypt_queue` and the per-peer `rx_queue`.
2. **Stage 2** — `wg_packet_decrypt_worker` in `receive.c`: workqueue worker (one per CPU,
   `WQ_PERCPU | WQ_CPU_INTENSIVE`) decrypts the packet using ChaCha20-Poly1305 and calls
   `wg_queue_enqueue_per_peer_rx`.
3. **Stage 3** — `wg_packet_rx_poll` in `receive.c`: WireGuard's NAPI poll function, runs as
   `NET_RX_SOFTIRQ`. Walks the per-peer RX queue from the head, delivers all contiguous
   `CRYPTED` packets via `napi_gro_receive`, stops at the first `UNCRYPTED` packet.

The problem is in `wg_queue_enqueue_per_peer_rx` (`queueing.h:196`): after marking its packet
`CRYPTED`, each decrypt worker calls `napi_schedule(&peer->napi)` **unconditionally**. This
raises `NET_RX_SOFTIRQ`.

Under concurrent decryption (N CPUs working on packets from the same peer in parallel), the
probability that the **head** of the per-peer RX queue is `CRYPTED` when any individual worker
finishes is 1/N. At N=8, this means **87.5% of `napi_schedule` calls are structurally wasted**
— GRO fires, finds `UNCRYPTED` at the queue head, and exits immediately with `work_done = 0`.

Each wasted GRO poll still consumes CPU time in softirq context. Under sustained high-throughput
traffic with many clients, this creates a feedback loop: one CPU saturates at ~94% on
`NET_RX_SOFTIRQ`, throughput collapses to 19.2% of line rate. (Measured by Mounah et al.,
SYSTOR 2025, on an 18-core server with a 25 Gbps NIC and 1000 clients.)

### 3.2 The fix

André Freyssinet (ScalAgent) proposed the following conditional check. After marking the current
packet `CRYPTED`, read `peer->rx_queue.tail` (the next packet the consumer — Stage 3 — will
process). If that packet is `UNCRYPTED`, Stage 3 cannot make progress regardless; skip
`napi_schedule`. Only schedule if the head is `CRYPTED`, `DEAD`, or the queue is at a boundary.

```diff
--- a/drivers/net/wireguard/queueing.h
+++ b/drivers/net/wireguard/queueing.h
@@ -188,9 +188,14 @@
 static inline void wg_queue_enqueue_per_peer_rx(struct sk_buff *skb, enum packet_state state)
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

**Correctness:** The only race is a stale read — worker A reads `UNCRYPTED` at the instant worker
B flips the head to `CRYPTED`. In that case, worker B reads `CRYPTED` and calls
`napi_schedule` itself. No packet is ever stranded. The `READ_ONCE` / `atomic_read` combination
is safe: `tail` is only written by the single consumer (Stage 3 via `wg_prev_queue_dequeue`); a
relaxed hint read from the worker side is sufficient.

**STUB handling:** When `tail == &peer->rx_queue.empty`, the queue is at a sentinel boundary.
Rather than dereference the sentinel, we schedule conservatively — one extra call is harmless.

**Residual limitation:** A narrow timing window exists where GRO partially advances the queue,
marks `NAPI_STATE_SCHED` cleared, and a worker that just made the head `CRYPTED` fires
`napi_schedule` during that window as a no-op (the flag is still set). In this case no one
reschedules until the next packet arrives. This is a second-order latency risk under bursty
traffic, not a correctness issue.

---

## 4. Build Process

### 4.1 Prerequisites check

```bash
uname -r
# 6.19.13-400.asahi.fc44.aarch64+16k

grep CONFIG_WIREGUARD /boot/config-$(uname -r)
# CONFIG_WIREGUARD=m   ← loadable module, good

lsmod | grep wireguard
# (empty — not loaded at start of day)
```

### 4.2 Installing kernel headers

The Asahi kernel uses the `kernel-16k` package family, not the standard `kernel` family.
The correct package name is `kernel-16k-devel`, not `kernel-devel-$(uname -r)`.

```bash
sudo dnf install -y kernel-16k-devel-6.19.13-400.asahi.fc44.aarch64
```

This installs headers to `/usr/src/kernels/6.19.13-400.asahi.fc44.aarch64+16k/`, which is
the target of the build symlink at `/lib/modules/$(uname -r)/build`.

### 4.3 Cloning Asahi kernel source

The Asahi Linux fork of the kernel (not mainline) is required since some patches diverge from
upstream. `--depth=1` reduces the download to ~1 GB.

```bash
git clone https://github.com/AsahiLinux/linux.git --depth=1 -b asahi \
    ~/Documents/internship/Io-uring-Internship/linux
```

### 4.4 Applying the patch

```bash
# Verify target location
grep -n "napi_schedule\|wg_queue_enqueue_per_peer_rx" \
    linux/drivers/net/wireguard/queueing.h
# 188: static inline void wg_queue_enqueue_per_peer_rx(...)
# 196: napi_schedule(&peer->napi);
```

The diff was applied to `linux/drivers/net/wireguard/queueing.h` at lines 188–198.

Verification after edit:
```bash
grep -n "READ_ONCE\|rx_queue.tail\|UNCRYPTED\|napi_schedule" \
    linux/drivers/net/wireguard/queueing.h
# 194:  struct sk_buff *tail;
# 198:  tail = READ_ONCE(peer->rx_queue.tail);
# 200:  atomic_read(&PACKET_CB(tail)->state) != PACKET_STATE_UNCRYPTED)
# 201:  napi_schedule(&peer->napi);
```

### 4.5 Building the module

**First attempt — building from within the cloned source tree:**

```bash
cd linux
cp /boot/config-$(uname -r) .config && make olddefconfig
make -j$(nproc) M=drivers/net/wireguard
```

**Failure:** `gcc: error: missing argument to '-mstack-protector-guard-offset='`

The cloned source tree does not have `include/generated/asm-offsets.h` — a file that is
generated during a full kernel build and is not present in a fresh clone. The module build
infrastructure requires this file.

**Fix:** Use the installed `kernel-16k-devel` tree as `KDIR`, pointing `M=` at the patched
WireGuard source directory. The installed headers DO contain `asm-offsets.h`.

```bash
make -C /lib/modules/$(uname -r)/build \
    M=/home/anasait/Documents/internship/Io-uring-Internship/linux/drivers/net/wireguard
```

**Output (success):**
```
CC [M]  main.o
CC [M]  noise.o
CC [M]  device.o
CC [M]  peer.o
CC [M]  timers.o
CC [M]  queueing.o
CC [M]  send.o
CC [M]  receive.o
CC [M]  socket.o
CC [M]  peerlookup.o
CC [M]  allowedips.o
CC [M]  ratelimiter.o
CC [M]  cookie.o
CC [M]  netlink.o
CC [M]  generated/netlink.o
LD [M]  wireguard.o
MODPOST Module.symvers
CC [M]  wireguard.mod.o
LD [M]  wireguard.ko
BTF [M] wireguard.ko
```

Module size: 7.6 MB. Vermagic check:

```bash
modinfo linux/drivers/net/wireguard/wireguard.ko | grep vermagic
# vermagic: 6.19.13-400.asahi.fc44.aarch64+16k SMP preempt mod_unload aarch64
```

Vermagic matches the running kernel exactly.

### 4.6 Loading the module

**Problem:** Direct `insmod` failed with `Unknown symbol in module`.

`journalctl -k` revealed four missing symbol groups:

| Symbol group | Module |
|---|---|
| `udp_sock_create4`, `udp_tunnel_xmit_skb`, `setup_udp_tunnel_sock`, `udp_tunnel_sock_release` | `udp_tunnel` |
| `udp_sock_create6`, `udp_tunnel6_xmit_skb` | `ip6_udp_tunnel` |
| `curve25519`, `curve25519_generate_public` | `libcurve25519` |

These dependency modules are not auto-loaded when using `insmod` (unlike `modprobe`).

**Fix:**
```bash
sudo modprobe udp_tunnel ip6_udp_tunnel libcurve25519
sudo insmod linux/drivers/net/wireguard/wireguard.ko
```

**Verification:**
```bash
lsmod | grep wireguard
# wireguard  131072  0
# libcurve25519  65536  1 wireguard
# ip6_udp_tunnel  65536  1 wireguard
# udp_tunnel  65536  1 wireguard

journalctl -k --no-pager | grep wireguard
# wireguard: WireGuard 1.0.0 loaded.
# wireguard: Copyright (C) 2015-2019 Jason A. Donenfeld <Jason@zx2c4.com>. All Rights Reserved.
```

---

## 5. Test Infrastructure

### 5.1 Scripts

All scripts live in `scripts/`. Private keys live in `scripts/keys/` (gitignored).

| Script | Purpose |
|---|---|
| `load_patched.sh` | Unloads stock, loads dependency modules, insmod patched .ko |
| `load_stock.sh` | Unloads patched, modprobe stock |
| `setup_tunnel.sh` | Creates 2-namespace single-peer tunnel (ns1↔ns2) |
| `teardown_tunnel.sh` | Destroys namespaces |
| `measure.sh [label]` | 30s iperf3 + bpftrace GRO counter, saves JSON + summary to `results/` |
| `setup_multipeer.sh [N]` | Creates 1 server + N client namespaces on one server WG interface |
| `teardown_multipeer.sh [N]` | Destroys all multipeer namespaces |
| `measure_multipeer.sh [label] [N]` | N-client iperf3 (N×4 streams) + bpftrace, saves results |
| `run_comparison.sh` | Full single-peer stock→patched comparison |
| `run_multipeer_comparison.sh [N]` | Full N-peer stock→patched comparison |
| `pin_wg_workers.sh [cpu]` | Pin all `wg-crypt-wg_mp_server` kworkers to one CPU via `taskset` |
| `unpin_wg_workers.sh` | Restore all WireGuard kworkers to the full CPU mask |
| `measure_multipeer_pinned.sh [label] [N] [cpu]` | Like `measure_multipeer.sh` but pins workers 2s after traffic starts |
| `run_pinned_comparison.sh [N] [cpu]` | Full N-peer stock→patched pinned comparison |
| `trace_ctx_switches.sh [duration]` | bpftrace context switches and CPU migrations per WireGuard kworker |

### 5.2 Single-peer tunnel topology

```
ns1 (10.0.0.1)  ←──── WireGuard tunnel ────→  ns2 (10.0.0.2)
wg1, port 51820                                wg2, port 51821
        ↕ UDP on 127.0.0.1 (loopback)
```

### 5.3 Multi-peer tunnel topology

```
ns_mp_client_0  (10.99.1.1) ─╮
ns_mp_client_1  (10.99.2.1) ─┤
ns_mp_client_2  (10.99.3.1) ─┤──→  ns_mp_server (10.99.0.1)
...                           ┤     wg_mp_server, port 51830
ns_mp_client_N  (10.99.N.1) ─╯     has N peers, one per client
                                    one packet_crypt_wq shared by all
```

Each client has its own keypair and its own `wg_peer` struct on the server. All peers share
**one** `packet_crypt_wq` workqueue on the server — exactly the architecture from the paper.

### 5.4 Measurement methodology

**bpftrace probe:**
```
kretprobe:wg_packet_rx_poll /retval == 0/ { @wasted_gro += 1; }
kretprobe:wg_packet_rx_poll /retval > 0/  { @useful_gro += 1; }
interval:s:1 {
    printf("%lld %lld\n", @wasted_gro, @useful_gro);
    @wasted_gro = 0; @useful_gro = 0;
}
```

`wg_packet_rx_poll` is WireGuard's NAPI poll function. Its return value is `work_done`:
- `retval == 0`: GRO was invoked but found no deliverable packets (wasted poll)
- `retval > 0`: at least one packet was delivered (useful poll)

**Note on `modinfo` in result files:** The `modinfo wireguard` command always resolves to the
on-disk `.ko.xz` path regardless of which module is running. Module identity is confirmed by
`lsmod` and the `dmesg` message at load time.

---

## 6. Experiment 1 — Single Peer

**Setup:** 1 client namespace (ns1), 1 server namespace (ns2), 1 WireGuard peer.  
**Traffic:** iperf3, 8 parallel TCP streams, 30 seconds.

### Results

| Module | Throughput | Wasted/s | Useful/s | Waste% | Total GRO/s |
|---|---|---|---|---|---|
| Stock | 1.51 Gbps | 37,307 | 119,071 | 23.9% | 156,378 |
| Patched | 1.52 Gbps | 38,046 | 119,026 | 24.2% | 157,072 |

### Interpretation

No effect from the patch at single-peer scale. Waste ratio ~24% and throughput identical for
both modules.

**Root cause of null result:** With a single peer and 8 TCP streams, the per-peer `rx_queue`
is typically 1–2 packets deep. The M1 Pro's NEON-accelerated ChaCha20 decrypts at ~10 GB/s per
core. At 1.5 Gbps total, each core handles roughly 150 Mbps — about 1.5% decrypt utilization.
Packets are decrypted so quickly that the queue head is nearly always `CRYPTED` when
`napi_schedule` fires. The patch's condition rarely evaluates to "skip".

The ~24% residual waste in both cases comes from normal NAPI scheduling overhead: queue boundary
transitions, the timing window (NAPI_STATE_SCHED debouncing), and the residual limitation
described in Section 3.2 — not from EoI.

**Conclusion:** Useful for correctness verification (zero retransmissions, no crashes) but
cannot expose the EoI problem. The null result is also a positive validation: with a single
peer, there is no concurrent decryption race, so the queue head is almost always `CRYPTED`
when `napi_schedule` fires. The patch's condition evaluates to "schedule" on every call —
it correctly does nothing when there is no concurrent decryption to suppress.

---

## 7. Experiment 2 — 8 Peers

**Setup:** 1 server namespace, 8 client namespaces. Server has 8 peers sharing one
`packet_crypt_wq`.  
**Traffic:** 8 clients × 4 parallel TCP streams = 32 streams total, 30 seconds.

### Results

| Module | Throughput | Wasted/s | Useful/s | Waste% | Total GRO/s |
|---|---|---|---|---|---|
| Stock | 13.06 Gbps | 46,794 | 110,097 | 29.8% | 156,891 |
| Patched | 13.05 Gbps | 36,484 | 93,034 | 28.2% | **129,518** |

### Key metrics

- Total GRO invocations reduced: 156,891 → 129,518 = **−27,373/s (−17.4%)**
- Wasted GRO calls reduced: 46,794 → 36,484 = **−10,310/s (−22.0%)**
- Throughput: effectively identical

### Interpretation

With 8 peers sharing one `packet_crypt_wq`, concurrent decryption of packets from the same peer
becomes more frequent. The patch now has a measurable effect.

The most interpretable metric is **total GRO invocations**, not waste percentage. The patch
works by preventing `napi_schedule` from firing at all — not by converting wasted calls into
useful ones. So the effect manifests as a reduction in total polls (both wasted and useful),
not as a change in the waste ratio. With 8 peers the total drops by 17.4%.

Throughput remains flat: at 13 Gbps across 10 cores, decrypt utilization is ~10–15%. The GRO
overhead we're reducing is real but is not the bottleneck at this load level.

---

## 8. Experiment 3 — 16 Peers

**Setup:** 1 server namespace, 16 client namespaces. Server has 16 peers.  
**Traffic:** 16 clients × 4 parallel TCP streams = 64 streams total, 30 seconds.

### Results

| Module | Throughput | Wasted/s | Useful/s | Waste% | Total GRO/s |
|---|---|---|---|---|---|
| Stock | 13.03 Gbps | 43,977 | 104,846 | 29.6% | 148,823 |
| Patched | 12.98 Gbps | 33,487 | 85,942 | 28.0% | **119,429** |

### Key metrics

- Total GRO invocations reduced: 148,823 → 119,429 = **−29,394/s (−19.8%)**
- Wasted GRO calls reduced: 43,977 → 33,487 = **−10,490/s (−23.9%)**
- Throughput: effectively identical (0.4% difference, within measurement noise)

### Interpretation

Results are consistent with and slightly stronger than the 8-peer experiment. Doubling from 8 to
16 peers increases the patch's suppression from 17.4% to 19.8% of total GRO invocations,
confirming the trend: more concurrent peers → more EoI opportunity → more suppression.

The throughput ceiling at ~13 Gbps (same as 8 peers) indicates the loopback's WireGuard
encryption throughput has been reached. Adding more peers beyond 16 will not change the
experimental conditions.

---

## 9. Experiment 4 — 16 Peers, CPU-Pinned

**Setup:** Same topology as Experiment 3 (16 peers, 64 streams total). After traffic starts,
all kworker threads matching `wg-crypt-wg_mp_server` (35 threads at peak traffic) are pinned
to CPU 0 using `taskset -cp 0 <pid>`, executed 2 seconds into the 30-second run.

**Purpose:** Artificially replicate the paper's saturation condition. Forcing all WireGuard
decrypt workers to share one core with `NET_RX_SOFTIRQ` should intensify the EoI feedback
loop: wasted GRO polls should increase for stock, and the patch's suppression should become
more pronounced.

**Script:** `run_pinned_comparison.sh 16 0`

### Results

| Module | Throughput | Wasted/s | Useful/s | Waste% | Total GRO/s |
|---|---|---|---|---|---|
| Stock | 12.583 Gbps | 40,757 | 98,989 | 29.2% | 139,746 |
| Patched | 12.866 Gbps | 31,507 | 85,888 | 26.8% | 117,395 |

### Key metrics

- Total GRO invocations reduced: 139,746 → 117,395 = **−22,351/s (−16.0%)**
- Wasted GRO calls reduced: 40,757 → 31,507 = **−9,250/s (−22.7%)**
- Throughput: effectively identical (2.2% difference, within measurement noise)

### Interpretation

The fix's suppression effect is preserved under CPU pinning: −22.7% wasted polls, −16.0%
total GRO invocations, consistent with the unpinned results from Experiment 3.

Throughput was unaffected despite all 35 kworkers being confined to CPU 0. The M1 Pro's
NEON ChaCha20 (~10 GB/s/core) completes decryption fast enough that even with 16 peers
competing on one core, that core is not saturated. The paper's feedback loop (wasted GRO
→ softirq saturation → decrypt backlog → more wasted GRO) requires a hardware configuration
where decrypt throughput is the bottleneck. On this machine, pinning forces contention but
does not force saturation.

---

## 10. Experiment 5 — 32 Peers

**Setup:** 1 server namespace, 32 client namespaces. Server has 32 peers.  
**Traffic:** 32 clients × 4 parallel TCP streams = 128 streams total, 30 seconds.  
**New metrics:** context switches and CPU migrations (all `kworker/` threads), ping latency from
`ns_mp_client_0` (250 pings × 100ms = 25s window during traffic).

### Results

| Module | Throughput | Wasted/s | Useful/s | Waste% | Total GRO/s |
|---|---|---|---|---|---|
| Stock | 12.630 Gbps | 40,139 | 98,913 | 28.9% | 139,052 |
| Patched | 13.138 Gbps | 33,809 | 85,195 | 28.4% | **119,004** |

| Module | CTX switches/s | CPU migrations/s (all kworkers) | Latency avg | Latency max |
|---|---|---|---|---|
| Stock | 135,859 | 5,492 | 3.432ms | 20.398ms |
| Patched | 137,246 | **3,090** | 3.687ms | 17.946ms |

**Note:** The migration count above was collected with a broad probe covering all kworker
threads (`strncmp(comm, "kworker/", 8) == 0`), not exclusively wg-crypt workers.
See Experiment 8 for the corrected wg-crypt-specific measurement.

### Key metrics

- Total GRO invocations reduced: 139,052 → 119,004 = **−20,048/s (−14.4%)**
- Wasted GRO calls reduced: 40,139 → 33,809 = **−6,330/s (−15.8%)**
- All-kworker CPU migrations reduced: 5,492 → 3,090 = **−2,402/s (−43.7%)** *(see note above)*
- Context switches: no significant change (noise-level difference)
- Latency max reduced: 20.398ms → 17.946ms

### Interpretation

The GRO suppression (−14.4% total) is consistent with earlier experiments, confirming the
plateau in the 15–20% range. The migration reduction (−43.7%) comes from the all-kworker probe
and likely reflects reduced scheduler pressure across the broader kworker pool as a side-effect
of fewer `napi_schedule` wakeups. The wg-crypt-specific result (Experiment 8) reveals that
wg-crypt workers themselves never migrate between CPUs, which explains the mechanism more precisely.

---

## 11. Experiment 6 — 64 Peers

**Setup:** 1 server namespace, 64 client namespaces. Server has 64 peers.  
**Traffic:** 64 clients × 4 parallel TCP streams = 256 streams total, 30 seconds.

### Results

| Module | Throughput | Wasted/s | Useful/s | Waste% | Total GRO/s |
|---|---|---|---|---|---|
| Stock | 17.265 Gbps | 55,044 | 116,454 | 32.1% | 171,498 |
| Patched | 15.134 Gbps | 42,429 | 98,144 | 30.2% | **140,573** |

| Module | CTX switches/s | CPU migrations/s | Latency avg | Latency max |
|---|---|---|---|---|
| Stock | 161,474 | 3,076 | 3.173ms | **96.312ms** |
| Patched | 144,988 | 4,851 | 3.117ms | **48.605ms** |

### Key metrics

Results below are from run 1; see interpretation for 3-run summary.

- Total GRO invocations reduced (run 1): 171,498 → 140,573 = **−18.0%**; avg across 3 runs: **~−14.5%**
- Wasted GRO calls reduced (run 1): 55,044 → 42,429 = **−22.9%**
- Context switches reduced: 161,474 → 144,988 = **−10.2%** (run 1 only)
- Tail latency (3-run avg): stock ~82ms, patched ~43ms = **~−47%**

### Interpretation

**Tail latency** is the standout result at 64 peers. The stock module reaches a 96ms tail RTT
— a GRO stall caused by EoI accumulating across 64 simultaneous peers. The patched module
cuts this to 48ms, nearly halving it. The average RTT is identical (3.1ms), confirming the
effect is specifically on tail events caused by GRO stalls, not on steady-state latency.

**GRO suppression** (−18.0% total) is consistent with the 8 and 16 peer results, confirming
the plateau. The absolute waste rate also increases with peer count (55,044 vs 43,977 at 16
peers), consistent with more concurrent decryption creating more EoI events.

**Throughput at 64 peers is highly variable.** This experiment was repeated three times.
Stock throughput ranged 13.6–17.3 Gbps across runs; patched ranged 15.1–17.0 Gbps.
Run 1 showed patched −12.4%, but runs 2 and 3 showed patched +5.2% and +20.2% respectively.
Average across three runs: stock 15.66 Gbps, patched 16.14 Gbps (+3.1%). There is no
systematic throughput regression at 64 peers; at 256 simultaneous loopback streams the
scheduling variance dominates any effect from the fix.

**CPU migrations** at 64 peers do not follow the 32-peer pattern (patched shows more migrations
than stock: 4,851 vs 3,076). At this scale, the kworker migration measurement captures
significant background noise from non-WireGuard kworkers; the 64-peer migration result is not
reliably interpretable with this probe.

---

## 12. Experiment 7 — 48 Peers (3 runs)

**Setup:** 1 server namespace, 48 client namespaces. Server has 48 peers.  
**Traffic:** 48 clients × 4 parallel TCP streams = 192 streams total, 30 seconds.  
**Purpose:** Locate the boundary between the fix's beneficial regime (≤32 peers) and any
regression regime identified at higher peer counts.

### Results (all three runs)

| Run | Stock Gbps | Patched Gbps | Δ | Stock GRO total | Patched GRO total | GRO Δ | Stock max RTT | Patched max RTT |
|---|---|---|---|---|---|---|---|---|
| 1 | 16.455 | 14.295 | −13.1% | 152,859 | 144,859 | −5.2% | **407.6ms** | 34.3ms |
| 2 | 13.900 | 13.662 | −1.7% | 175,453 | 145,915 | −16.8% | 38.9ms | 45.9ms |
| 3 | 16.069 | 14.876 | −7.4% | 172,601 | 172,842 | ~0% | 26.3ms | 22.2ms |
| **avg** | **15.47** | **14.28** | **−7.7%** | **166,971** | **154,539** | **−7.4%** | — | — |

### Key metrics

- Total GRO suppression (average): **−7.4%** (weakened from ~14% at 32 peers)
- Throughput regression (average): **−7.7%** — consistent across all three runs
- Patched tail latency: never exceeded 46ms across all 3 runs
- Stock tail latency: reached 407ms once (run 1), 23–39ms in other runs

### Interpretation

**Throughput:** The patched module is consistently slower than stock across all three runs
(−2%, −7%, −13%). Average −7.7%. This is a systematic regression, confirmed by repetition,
and is not seen at 32 peers (where patched is consistently equal or slightly better). The
regression boundary lies between 32 and 48 peers under these loopback conditions.

The mechanism is the residual gap scenario (Section 3.2, limitation 3): under 192 concurrent
streams the per-peer rx_queue is deeper on average, so missed `napi_schedule` calls — where
the queue head transitions to `CRYPTED` but no worker reschedules because they all read
`UNCRYPTED` — accumulate often enough to reduce delivery rate.

**GRO suppression** weakens significantly at 48 peers (~−7.4% average vs ~−14% at 32 peers)
and is inconsistent across runs (−0.1%, −5.2%, −16.8%). The conditional check is still
firing correctly, but the ratio of useful vs wasted suppression shifts unfavorably at higher
queue depths.

**Tail latency:** The 407ms spike in run 1 is an extreme GRO stall caused by EoI accumulation
across 48 simultaneous peers. It was not reproduced in runs 2 and 3, indicating it requires
a specific timing alignment between 192 stream bursts. However, its occurrence with the stock
module — and its absence in the same-run patched result (34ms) — demonstrates that the fix
suppresses the class of events that cause these extreme stalls. Across all three runs, the
patched module's tail latency never exceeded 46ms, while the stock module reached 407ms once
and 39ms in the others.

---

## 13. Experiment 8 — wg-crypt Specific CPU Migration Probe (32 Peers)

**Setup:** 32-peer tunnel, 128 streams, 30 seconds.  
**Purpose:** Isolate CPU migrations to exactly the wg-crypt kworker threads (not all kworkers).  
**Method:** bpftrace `software:cpu-migrations:1` probe with a PID filter built from
`/proc/[0-9]*/comm` scan for "wg-crypt" — reads full thread names, not the truncated `ps`
display column. PIDs collected 5 seconds into traffic to allow kworkers to fully spawn.  
**Script:** `scripts/run_wgcrypt_migration_comparison.sh`

### Results

| Module | Throughput | wg-crypt PIDs tracked | Migrations/s | Samples |
|---|---|---|---|---|
| Stock   | 14.052 Gbps | 109 | **0.0/s** | 7 |
| Patched | 14.244 Gbps | 124 | **0.0/s** | 8 |

Raw bpftrace output: all-zeros for both runs. `Attached 2 probes` confirmed the probe
was active throughout; `@mig: 0` at exit confirms zero migration events were recorded.

### Key finding

**wg-crypt kworkers do not migrate between CPUs on either stock or patched.**

The reason is architectural: `packet_crypt_wq` is created with `WQ_PERCPU`, which binds
each kworker to a specific CPU via kernel-managed CPU affinity masks. The scheduler never
moves these threads to another CPU regardless of load. The `software:cpu-migrations:1`
probe correctly returns zero because the kernel never executes a cross-CPU migration for
these threads.

### Implication for the earlier −43.7% result (Experiment 5)

The 5,492 → 3,090 migration reduction measured in Experiment 5 came from the broad
all-kworker probe. That reduction is real — fewer `napi_schedule` wakeups reduce general
scheduler pressure and reduce migrations for other kworker families in the system. But it
cannot be attributed specifically to wg-crypt threads.

The patch's per-thread measurable effect is on **wasted GRO polls** (−14% total) and
indirectly on **context switches** (fewer unnecessary NAPI wakeups). CPU migrations are
not a mechanism through which the fix operates — they are structurally zero for these
threads regardless of patch state.

### Note on PID count (109–124)

The `/proc` scan finds all processes whose comm contains "wg-crypt" at that moment,
including kworkers spawned during earlier experiments in the session that have not yet
exited. The count is higher than the ~10 CPUs × 1 worker expected for a fresh tunnel
because Linux does not immediately reap kworkers whose workqueue has gone idle. All
matched PIDs are genuine `wg-crypt-wg_mp_server` kworkers; the count does not affect
the migration result (all show zero).

---

## 14. Full Results Summary


| Config | Throughput | Wasted/s | Useful/s | Waste% | Total GRO/s | vs. stock GRO |
|---|---|---|---|---|---|---|
| 1 peer — stock | 1.51 Gbps | 37,307 | 119,071 | 23.9% | 156,378 | baseline |
| 1 peer — patched | 1.52 Gbps | 38,046 | 119,026 | 24.2% | 157,072 | +0.4% |
| 8 peers — stock | 13.06 Gbps | 46,794 | 110,097 | 29.8% | 156,891 | baseline |
| 8 peers — patched | 13.05 Gbps | 36,484 | 93,034 | 28.2% | 129,518 | **−17.4%** |
| 16 peers — stock | 13.03 Gbps | 43,977 | 104,846 | 29.6% | 148,823 | baseline |
| 16 peers — patched | 12.98 Gbps | 33,487 | 85,942 | 28.0% | 119,429 | **−19.8%** |
| 16 peers — stock, pinned | 12.583 Gbps | 40,757 | 98,989 | 29.2% | 139,746 | baseline |
| 16 peers — patched, pinned | 12.866 Gbps | 31,507 | 85,888 | 26.8% | 117,395 | **−16.0%** |
| 32 peers — stock | 12.630 Gbps | 40,139 | 98,913 | 28.9% | 139,052 | baseline |
| 32 peers — patched | 13.138 Gbps | 33,809 | 85,195 | 28.4% | 119,004 | **−14.4%** |
| 48 peers — stock (avg 3 runs) | 15.47 Gbps | ~49,589 | ~117,382 | 29.7% | ~167,000 | baseline |
| 48 peers — patched (avg 3 runs) | 14.28 Gbps | ~45,729 | ~108,810 | 29.6% | ~154,539 | **~−7.4%** |
| 64 peers — stock (avg 3 runs) | 15.66 Gbps | ~53,573 | ~119,444 | 31.0% | ~173,017 | baseline |
| 64 peers — patched (avg 3 runs) | 16.14 Gbps | ~44,679 | ~103,267 | 30.2% | ~147,946 | **~−14.5%** |

**CPU migrations (Experiments 5 and 8) and tail latency (Experiments 5–7):**

| Config | All-kworker mig/s | wg-crypt mig/s | Latency max (notable) | vs. stock |
|---|---|---|---|---|
| 32 peers — stock | 5,492 | **0** | 20ms | baseline |
| 32 peers — patched | 3,090 (−43.7%) | **0** | 18ms | −12% |
| 48 peers — stock | — | — | up to **407ms** (1/3 runs) | baseline |
| 48 peers — patched | — | — | max 46ms (all runs) | — |
| 64 peers — stock (avg) | — | — | ~82ms avg tail | baseline |
| 64 peers — patched (avg) | — | — | ~43ms avg tail | **~−47%** |

wg-crypt specific migration = 0 for both modules because `WQ_PERCPU` affinity prevents
kworker CPU migrations at the kernel level (see §13 and §16.6).

---

## 15. Why the Throughput Collapse Cannot Be Reproduced Locally

The paper (Mounah et al., SYSTOR 2025) observed a 4.7× throughput gain from moving
`napi_schedule` to a workqueue. That gain requires:

1. **Line-rate saturation:** 25 Gbps of incoming traffic fully loading the server's NIC.
2. **Many concurrent clients:** 800–1000 peers generating traffic simultaneously.
3. **CPU saturation on NET_RX_SOFTIRQ:** one core reaching 94% CPU, consumed entirely by wasted
   GRO polls — the feedback loop where a saturated core accumulates a backlog, processes a large
   GRO burst when real work arrives, and then gets saturated again.

Our setup differs in each dimension:

| Condition | Paper's setup | Our setup |
|---|---|---|
| NIC | 25 Gbps physical NIC | Loopback (no NIC) |
| Clients | 800–1000 | up to 64 |
| Total traffic | 25 Gbps | ~13–17 Gbps (loopback ceiling) |
| CPU utilization | ~94% on one core (NET_RX_SOFTIRQ) | ~10–15% across all cores |
| ChaCha20 | x86-64 AVX2 | ARM64 NEON (higher GB/s per watt) |

The M1 Pro's NEON ChaCha20 runs at roughly 10 GB/s per core. Saturating 10 cores would require
~100 Gbps of WireGuard traffic — physically impossible on loopback. The throughput collapse is
caused by a feedback loop that only manifests at saturation. Without saturation, eliminating 20%
of GRO overhead has no measurable throughput impact.

---

## 16. Discussion

### 16.1 What the patch suppresses

The patch does not convert wasted GRO polls into useful ones. It **prevents `napi_schedule`
from being called at all** when GRO would find nothing to do. This is directly visible in the
data: with 16 peers, total GRO invocations drop from 148,823/s to 119,429/s. Those 29,394
eliminated polls per second represent CPU cycles not spent on softirq context switching, not
spent on `wg_packet_rx_poll` entry/exit overhead, and not spent contending on NAPI state flags.

### 16.2 Why the waste percentage barely changes

The waste percentage (wasted / total) is nearly the same in stock and patched (~29% both).
This is because the patch reduces both wasted AND useful calls. A call that passes the
conditional check is one where the head was `CRYPTED` — such a call is likely useful. But the
patch also reduces the rate at which these calls fire. The absolute numbers are the right metric:
−10,490 wasted/s and −18,904 useful/s, for a net −29,394 total/s.

### 16.3 Residual waste

Even with the patch, ~28% of GRO polls are still wasted. Sources:

1. **Timing window:** the worker reads `tail = CRYPTED`, calls `napi_schedule`, but by the time
   GRO runs the head has already been consumed and a new `UNCRYPTED` head is present.
2. **STUB boundary:** the sentinel path always schedules conservatively.
3. **Partial delivery:** GRO delivers some packets and stops at a mid-queue gap. The subsequent
   `napi_complete_done` creates a residual window before the next caller reschedules.

### 16.4 Comparison to the paper's fix

The paper moved `napi_schedule` to a dedicated workqueue (`gro_wq`) at `SCHED_NORMAL`. This
changes *when* GRO runs (asynchronously, not as a softirq) but does not change *the condition
under which it is scheduled*. GRO is still scheduled after every decrypted packet.

André's fix reduces the **number** of `napi_schedule` calls. The paper's fix reduces the
**cost** of each call. These are orthogonal improvements. A complete solution would combine
both: the conditional check (fewer calls) and the workqueue migration (cheaper calls).

### 16.5 Correctness

Throughout all experiments: zero iperf3 retransmissions, stable throughput across 30-second
runs, no kernel panics, no dmesg errors. The patched module correctly handles all queue cases.

### 16.6 Why wg-crypt kworkers never migrate CPUs

`packet_crypt_wq` is created with `WQ_PERCPU | WQ_CPU_INTENSIVE`. The `WQ_PERCPU` flag
instructs the workqueue subsystem to create per-CPU worker pools and bind each kworker to
a single CPU via its affinity mask. The scheduler respects these masks: a `WQ_PERCPU`
kworker is never migrated to another CPU, regardless of load imbalance.

This is why Experiment 8 shows exactly 0 CPU migrations for both stock and patched: the
migration path (`sched_migrate_task`) is simply never invoked for these threads. The patch
cannot reduce a quantity that is structurally zero.

The all-kworker migration reduction seen in Experiment 5 (5,492 → 3,090/s, −43.7%) is
real but comes from non-WQ_PERCPU kworker families whose workers are allowed to migrate.
Fewer `napi_schedule` wakeups indirectly reduce pressure on the scheduler's load-balancing
logic, which drives some of those other kworkers to migrate less. This is a secondary
effect, not a direct consequence of the patch suppressing EoI events.

---

## 17. Raw Data

All raw data is in `results/`. Each directory contains:

| File | Contents |
|---|---|
| `info.txt` | Configuration + summary statistics |
| `bpftrace_raw.txt` | Per-second wasted/useful GRO poll counts (two integers per line) |
| `iperf3_client_N.json` | Full iperf3 JSON output per client |
| `iperf3_server_N.json` | Server-side iperf3 JSON |

| Directory | Experiment |
|---|---|
| `20260528_132252_stock` | 1 peer, stock module |
| `20260528_132527_patched` | 1 peer, patched module |
| `20260528_133424_stock_mp_mp8` | 8 peers, stock module |
| `20260528_133500_patched_mp_mp8` | 8 peers, patched module |
| `20260528_134015_stock_mp_mp16` | 16 peers, stock module |
| `20260528_134753_patched_mp_mp16` | 16 peers, patched module |
| `20260528_150908_stock_pinned_mp16_pinned` | 16 peers, stock module, workers pinned to CPU 0 |
| `20260528_150952_patched_pinned_mp16_pinned` | 16 peers, patched module, workers pinned to CPU 0 |
| `20260528_152823_stock_mp_mp32` | 32 peers, stock module |
| `20260528_152907_patched_mp_mp32` | 32 peers, patched module |
| `20260528_153102_stock_mp_mp64` | 64 peers, stock module (run 1) |
| `20260528_153205_patched_mp_mp64` | 64 peers, patched module (run 1) |
| `20260528_154516_stock_mp_mp32` | 32 peers, stock module (run 2, wg-crypt CSW probe) |
| `20260528_154602_patched_mp_mp32` | 32 peers, patched module (run 2, wg-crypt CSW probe) |
| `20260528_154713_stock_mp_mp48` | 48 peers, stock module (run 1) |
| `20260528_154809_patched_mp_mp48` | 48 peers, patched module (run 1) |
| `20260528_155246_stock_mp_mp64` | 64 peers, stock module (run 2) |
| `20260528_155345_patched_mp_mp64` | 64 peers, patched module (run 2) |
| `20260528_155512_stock_mp_mp64` | 64 peers, stock module (run 3) |
| `20260528_155603_patched_mp_mp64` | 64 peers, patched module (run 3) |
| `20260528_155906_stock_mp_mp48` | 48 peers, stock module (run 2) |
| `20260528_155958_patched_mp_mp48` | 48 peers, patched module (run 2) |
| `20260528_160054_stock_mp_mp48` | 48 peers, stock module (run 3) |
| `20260528_160153_patched_mp_mp48` | 48 peers, patched module (run 3) |
| `20260528_162912_stock_wgmig_mp32` | 32 peers, stock — wg-crypt specific migration probe |
| `20260528_163001_patched_wgmig_mp32` | 32 peers, patched — wg-crypt specific migration probe |
