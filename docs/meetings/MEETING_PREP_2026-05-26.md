# Meeting Prep — May 26, 2026
# Alain Tchana + André Freyssinet

---

## Since May 21 — what was done

- Answered all 5 open questions from the meeting (source code investigation)
- Resolved the exact form of André's condition (diff written and verified)
- Generated 7 pipeline diagrams covering the full architecture
- Started the final report (Abstract + Introduction + Background written)
- Next: apply the diff and run measurements today

---

## The 5 open questions — answered with source citations

---

### Q1 — How are packets from the same peer distributed across CPUs?

**Answer: same-peer packets are decrypted concurrently on different CPUs.**

`wg_queue_enqueue_per_device_and_peer` (`queueing.h:152`):

```c
// Phase 1: per-peer queue — establishes delivery order
wg_prev_queue_enqueue(peer_queue, skb);          // queueing.h:162

// Phase 2: global ring — establishes CPU assignment
cpu = wg_cpumask_next_online(&device_queue->last_cpu);  // queueing.h:164
ptr_ring_produce_bh(&device_queue->ring, skb);
queue_work_on(cpu, wq, &per_cpu_ptr(device_queue->worker, cpu)->work);
```

`wg_cpumask_next_online` (`queueing.h:115`): approximate round-robin. The comment at line 115–119 explicitly states:
> *"This function is racy, in the sense that it's called while last_cpu is unlocked, so it could return the same CPU twice. Adding locking or using atomic sequence numbers is slower though, and the consequences of racing are harmless."*

**Example:** 4 consecutive packets from Peer A → CPU 0, 1, 2, 3 simultaneously. CPU 2 finishes first. Packet 2 is CRYPTED. Packets 0 and 1 are still UNCRYPTED. GRO looks at packet 0 (the head) → UNCRYPTED → returns work_done = 0. Packet 2 is unreachable.

**Also confirmed:** the head packet (position 0) has a systematic disadvantage. CPU 0 may already be finishing a previous peer's packet when packet 0 arrives — so it starts decrypting packet 0 *later* than CPUs 1, 2, 3 start their packets. The head is the most likely to be the last one ready.

---

### Q2 — Is the napi_struct per-peer or per-packet?

**Answer: per-peer. One napi_struct per peer, for the lifetime of the peer.**

`peer.c:57`:
```c
netif_napi_add(wg->dev, &peer->napi, wg_packet_rx_poll);
```

`peer.c:58` (after full initialization):
```c
napi_enable(&peer->napi);  // sets state = SCHED=0, NAPI_STATE_NPSVC=0 (schedulable)
```

`peer.c:120` (peer teardown):
```c
napi_disable(&peer->napi);  // sets DISABLE bit — napi_schedule becomes no-op
```

**Consequence under concurrent decryption:** when N CPUs each finish a packet from the same peer, all N call `napi_schedule(&peer->napi)`. The first call sets `NAPI_STATE_SCHED`. All subsequent calls see the flag set and return immediately (no-op). GRO fires once — but it fires for whichever CPU happened to finish *first*, not the one whose packet is at the head of the queue.

---

### Q3 — Is GRO called after every packet, or is there batching?

**Answer: after every single packet, unconditionally. No batching.**

`queueing.h:196` (inside `wg_queue_enqueue_per_peer_rx`):
```c
atomic_set_release(&PACKET_CB(skb)->state, state);  // mark CRYPTED
napi_schedule(&peer->napi);                          // unconditional, every packet
```

`napi_schedule` raises `NET_RX_SOFTIRQ`. The softirq fires at the next `spin_unlock_bh` inside `ptr_ring_consume_bh` — i.e., at the very next iteration of the decrypt worker's consumption loop.

**What wg_packet_rx_poll does when it fires** (`receive.c:451`):
```c
while ((skb = wg_prev_queue_peek(&peer->rx_queue)) != NULL &&
       (state = atomic_read_acquire(&PACKET_CB(skb)->state)) !=
               PACKET_STATE_UNCRYPTED) {
    wg_prev_queue_drop_peeked(&peer->rx_queue);
    // ... deliver packet ...
    if (++work_done >= budget) break;   // budget = 64
}
```

The loop delivers **the full contiguous run from the head** — all non-UNCRYPTED packets until the first gap or budget exhaustion. It does not deliver individual packets.

**Key implication for the condition:** if the head is UNCRYPTED, `wg_packet_rx_poll` returns `work_done = 0` immediately. The state of any other packet in the queue is irrelevant — GRO cannot reach it.

`napi_complete_done` is called only when `work_done < budget` (`receive.c:487`), which clears `NAPI_STATE_SCHED` and re-arms the NAPI for the next scheduling.

---

### Q4 — Is skb an individual packet or a chain?

**Answer: on the RX path, one skb = one UDP datagram = one WireGuard data message = one inner IP packet.**

`receive.c:496–501` (decrypt worker consumption loop):
```c
while ((skb = ptr_ring_consume_bh(&decrypt_queue->ring)) != NULL) {
    wg_packet_decrypt_worker(skb);
    ...
}
```

`ptr_ring_consume_bh` returns a single pointer. On the RX side there is no chaining. (The TX side uses `skb_list_walk_safe` for batching, but that is the encrypt path — independent.)

Remark: skb is an individual packet because each decrypt worker is designed to process one packet at a time. The worker function (`wg_packet_decrypt_worker`) operates on a single skb, and the NAPI poll function (`wg_packet_rx_poll`) also processes one skb at a time from the head of the queue.

---

### Q5 — Software GRO vs hardware GRO?

**Answer: WireGuard uses software GRO only. Hardware GRO operates at a different layer and is completely independent.**

`receive.c` (`wg_packet_rx_poll`):
```c
napi_gro_receive(&peer->napi, skb);   // software GRO, called from poll function
```

Software GRO (`net/core/gro.c`) runs on the CPU inside `wg_packet_rx_poll`, reassembles inner IP packets from the decrypted WireGuard data messages, and passes them up the network stack.

Hardware GRO (if the physical NIC supports it) operates on **outer UDP packets** — before Stage 1 even runs. It merges multiple UDP datagrams at the NIC level. This is a completely different layer and does not interact with WireGuard's software GRO path.

---

## André's condition — resolved and verified

### The correct check

After all the source investigation, the correct trigger condition is:

> **Schedule GRO only if the head of `peer->rx_queue` is NOT UNCRYPTED.**

This is equivalent to André's original intent. Checking only the head is sufficient because `wg_packet_rx_poll` stops at the first UNCRYPTED packet regardless of what follows — so if the head is UNCRYPTED, GRO cannot make progress no matter what packet N's state is.

### Why we cannot use wg_prev_queue_peek from worker context

Both `wg_prev_queue_peek` and `wg_prev_queue_drop_peeked` are marked `/* Single consumer */` in `queueing.c:67,76`. The consumer is `wg_packet_rx_poll` (the NAPI poll function). Calling `wg_prev_queue_peek` from the decrypt worker would corrupt the `peeked` cache field if a NAPI poll is running concurrently on another CPU.

### Safe implementation: READ_ONCE(peer->rx_queue.tail)

`queue->tail` is only written by the consumer inside `wg_prev_queue_dequeue` (`queueing.c:87, 92, 101`). It is never written by the producer side. Reading it from worker context with `READ_ONCE` is safe as a hint — a stale read is not a correctness problem (see below).

STUB sentinel: `(struct sk_buff *)&peer->rx_queue.empty` (`queueing.c:51, 56`). When `tail == STUB`, the queue is on a boundary state — schedule conservatively to preserve liveness.

### The diff

```diff
diff --git a/drivers/net/wireguard/queueing.h b/drivers/net/wireguard/queueing.h
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

### The four cases

| Case | Situation | Decision | Source justification |
|---|---|---|---|
| A | Packet N is the head, just became CRYPTED | Schedule | `tail` state is now non-UNCRYPTED |
| B | N not head; head already CRYPTED or DEAD | Schedule | GRO finds work at the head; DEAD packets pass the poll loop (`receive.c:458`) |
| C | N not head; head is UNCRYPTED | Skip | GRO returns `work_done=0` immediately (`receive.c:451–453`) |
| D | N not head; gap between head and N | Skip | Subcase of C — head is UNCRYPTED regardless |
| STUB | Queue on sentinel boundary | Schedule | Conservative — avoids non-consumer pointer traversal |

### Safety — stale read

If worker reads `UNCRYPTED` at the instant another core flips the head to `CRYPTED`:
- This worker skips `napi_schedule`
- The core that performed the flip reads `CRYPTED` → calls `napi_schedule` itself
- No packet is stranded. No liveness is lost.

`atomic_read` (not `atomic_read_acquire`): this is a speculative hint, not a synchronization point. Relaxed read is correct and avoids the barrier cost.

### Residual limitation

After GRO delivers packets 0–1 and stops at packet 2 (UNCRYPTED), there is a narrow window between GRO stopping and `napi_complete_done` clearing `NAPI_STATE_SCHED`. If CPU 2 marks packet 2 CRYPTED inside this window:
1. CPU 2 checks head → CRYPTED → calls `napi_schedule`
2. `NAPI_STATE_SCHED` is still set → `napi_schedule` is a no-op
3. `napi_complete_done` clears the flag
4. No one reschedules — packets 2 and 3 wait for the next arrival

This is **not a correctness problem**. Under sustained traffic the next packet arrives in nanoseconds. Under bursty traffic it may appear as a rare tail latency spike. It is a second-order effect — the diff eliminates the primary overhead.

---

## Current state

| Item | Status |
|---|---|
| 5 open questions from May 21 | ✅ All answered with source citations |
| André's condition — exact form | ✅ Verified and diff written |
| 7 pipeline diagrams | ✅ Generated and reviewed |
| Final report | 🟡 Abstract + Introduction + Background written |
| Diff applied to kernel source | ⬜ Today |
| Baseline measurement | ⬜ Today |
| Patched measurement | ⬜ This week |

---

## Questions for the meeting

1. **Validate the diff** — does André agree with the READ_ONCE(tail) approach? Any concern about the STUB sentinel handling?
2. **Residual limitation** — is the mid-queue timing window worth addressing in the report, or out of scope for June 5?
3. **Paper's fix reproduction** — which workqueue did the paper use? Should we add a dedicated `gro_wq` to `device.c`?
4. **Measurement setup** — Brice / Teo's environment: is it available for the iperf3 baseline, or should I use a single-machine loopback setup?
5. **Report scope** — 6 pages is tight. Is it better to present strong bpftrace tracing evidence (wasted call frequency) even without the full patched measurement, or should we wait for the numbers?
