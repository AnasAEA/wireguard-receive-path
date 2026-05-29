# Bottleneck-Induction Patch — Tunable Decrypt Delay + Runtime Fix Toggle

**Purpose:** the M1 Pro's NEON ChaCha20 (~10 GB/s/core) is too fast to ever make
decryption the bottleneck on loopback, so the EoI feedback loop never engages and
throughput never collapses (see `EXPERIMENTS_2026-05-28.md` §15). This patch adds a
*controlled* per-packet decrypt cost so we can sweep it and find the threshold where
EoI starts to hurt throughput — a sensitivity analysis that substitutes for the
real-NIC saturation regime we cannot reach.

It exposes **two module parameters**, both writable at runtime via sysfs, so a single
`.ko` covers every configuration with no rebuild and no module swap:

| Parameter | Path | Meaning |
|---|---|---|
| `wg_decrypt_delay_us` | `/sys/module/wireguard/parameters/wg_decrypt_delay_us` | artificial busy-wait (µs) per decrypted packet; `0` = off |
| `wg_eoi_fix` | `/sys/module/wireguard/parameters/wg_eoi_fix` | `1` = conditional `napi_schedule` (André's fix), `0` = unconditional (stock behavior) |

So `wg_eoi_fix=0, delay=D` reproduces **stock behavior** at decrypt cost D, and
`wg_eoi_fix=1, delay=D` is the **patched** behavior at the same cost — an apples-to-apples
comparison from one binary.

---

## The diff

Apply on top of a clean Asahi WireGuard source (the delay/toggle replaces the
plain conditional from `ANDRE_SOLUTION_PROPOSAL.md`).

### `drivers/net/wireguard/queueing.h`

```diff
@@
+/* Experiment knobs (defined in receive.c). */
+extern int wg_eoi_fix;
+
 static inline void wg_queue_enqueue_per_peer_rx(struct sk_buff *skb, enum packet_state state)
 {
 	struct wg_peer *peer = wg_peer_get(PACKET_PEER(skb));
+	struct sk_buff *tail;
 
 	atomic_set_release(&PACKET_CB(skb)->state, state);
-	napi_schedule(&peer->napi);
+
+	if (!wg_eoi_fix) {
+		/* Stock behavior: unconditional schedule. */
+		napi_schedule(&peer->napi);
+	} else {
+		/* André's fix: skip if the consumer's next packet is still UNCRYPTED. */
+		tail = READ_ONCE(peer->rx_queue.tail);
+		if (tail == (struct sk_buff *)&peer->rx_queue.empty ||
+		    atomic_read(&PACKET_CB(tail)->state) != PACKET_STATE_UNCRYPTED)
+			napi_schedule(&peer->napi);
+	}
+
 	wg_peer_put(peer);
 }
```

### `drivers/net/wireguard/receive.c`

Add the includes near the top (if not already present):

```diff
 #include "queueing.h"
+#include <linux/delay.h>
+#include <linux/moduleparam.h>
```

Define the parameters (place after the existing includes, file scope):

```diff
+/* ── Experiment knobs ────────────────────────────────────────────────────────
+ * wg_decrypt_delay_us: artificial busy-wait per decrypted packet, to make
+ *   decryption the bottleneck on hardware where it otherwise is not.
+ * wg_eoi_fix: 1 = conditional napi_schedule (fix), 0 = unconditional (stock).
+ * Both are 0644 so they can be tuned at runtime via /sys/module/.../parameters.
+ */
+unsigned int wg_decrypt_delay_us;
+module_param(wg_decrypt_delay_us, uint, 0644);
+MODULE_PARM_DESC(wg_decrypt_delay_us, "artificial per-packet decrypt delay (us)");
+
+int wg_eoi_fix = 1;
+module_param(wg_eoi_fix, int, 0644);
+MODULE_PARM_DESC(wg_eoi_fix, "1=conditional napi_schedule fix, 0=stock unconditional");
```

In `wg_packet_decrypt_worker`, add the delay right after decryption:

```diff
 	while ((skb = ptr_ring_consume_bh(&queue->ring)) != NULL) {
 		enum packet_state state =
 			likely(decrypt_packet(skb, &PACKET_CB(skb)->keypair)) ?
 				PACKET_STATE_CRYPTED : PACKET_STATE_DEAD;
+		if (unlikely(wg_decrypt_delay_us))
+			udelay(wg_decrypt_delay_us);
 		wg_queue_enqueue_per_peer_rx(skb, state);
 		if (need_resched())
 			cond_resched();
 	}
```

> `udelay` is a busy-wait — it burns the CPU the way real crypto would, rather than
> sleeping. That is what we want: it makes the worker CPU-bound, faithfully
> emulating a slower cipher. Keep the swept values modest (≤ ~100 µs) so a worker
> never holds a CPU long enough to trip soft-lockup warnings.

---

## Build & load

```bash
make -C /lib/modules/$(uname -r)/build \
    M=$HOME/Documents/internship/Io-uring-Internship/linux/drivers/net/wireguard
sudo modprobe udp_tunnel ip6_udp_tunnel libcurve25519
sudo rmmod wireguard 2>/dev/null
sudo insmod linux/drivers/net/wireguard/wireguard.ko
```

Confirm the knobs exist:

```bash
ls /sys/module/wireguard/parameters/
cat /sys/module/wireguard/parameters/wg_eoi_fix          # 1
cat /sys/module/wireguard/parameters/wg_decrypt_delay_us # 0
```

Toggle at runtime (no reload):

```bash
echo 0  | sudo tee /sys/module/wireguard/parameters/wg_eoi_fix          # stock behavior
echo 40 | sudo tee /sys/module/wireguard/parameters/wg_decrypt_delay_us # 40 us/packet
```

---

## Running the sweep

`scripts/run_delay_sweep.sh` keeps one tunnel up, constrains WireGuard to a small
core set (default 2), and sweeps delay × {fix off, fix on}, writing one result dir
per cell plus a `SWEEP.csv`:

```bash
sudo bash scripts/run_delay_sweep.sh 16 30 "0 1" "0 5 10 20 40 80"
#                                     │  │   │      └ delays (us) to sweep
#                                     │  │   └ CPUs to keep online (contention)
#                                     │  └ seconds per cell
#                                     └ peers
```

**What to look for:** the delay D\* where stock-behavior throughput starts dropping
while patched holds — that crossover is a *local reproduction* of the paper's effect.
If patched throughput stays above stock for D ≥ D\*, you have a defensible result that
needs no real NIC. If they track together at all delays, that is also a finding: on
this architecture the EoI overhead is dominated by other costs.
