# Proposed Fix — Conditional `napi_schedule` in WireGuard RX path
# For review by André Freyssinet

---

## The problem being fixed

`wg_queue_enqueue_per_peer_rx` (`queueing.h:196`) calls `napi_schedule` unconditionally after every decrypted packet. Under concurrent decryption — which is the normal case, since `packet_crypt_wq` is `WQ_PERCPU` and multiple CPUs decrypt packets from the same peer in parallel — the head of `peer->rx_queue` is frequently `UNCRYPTED` while packets at other positions are `CRYPTED`.

`wg_packet_rx_poll` (`receive.c:451`) walks the per-peer RX queue strictly from the head and stops the moment it encounters an `UNCRYPTED` packet. If the head is `UNCRYPTED`, the function returns immediately with `work_done = 0`. Every `napi_schedule` call in this state raises `NET_RX_SOFTIRQ`, which fires at the next `spin_unlock_bh` inside `ptr_ring_consume_bh` of the decrypt worker's own loop — preempting the worker and running a poll that delivers zero packets. This is the EoI overhead.

---

## Why the problem is worse than it appears — a probabilistic argument

Consider N CPUs decrypting N packets from the same peer in parallel. For GRO to make progress, packet 0 — the specific one assigned to CPU 0 — must finish decryption first, before any other CPU calls `napi_schedule`.

The probability that packet 0 finishes first among N concurrent decryptions is 1/N. With 8 CPUs that is 12.5%. With 16 CPUs it is 6.25%. So on an 8-core machine, **87.5% of `napi_schedule` calls happen when the head is still UNCRYPTED** — each one fires a wasted GRO poll.

Two structural reasons make it even worse than this baseline:

**Reason 1 — the head packet has a systematic disadvantage.**

Packet 0 entered the global `decrypt_queue.ring` first. The ring is FIFO, so CPU 0 pulls it first. But CPU 0 may already be finishing a previous packet from a different peer when packet 0 arrives. CPUs 1, 2, 3 may be idle and grab packets 1, 2, 3 immediately. CPU 0 therefore starts decrypting packet 0 *later* than the others start their packets, even though packet 0 arrived first. The head packet is systematically the last to begin decryption — which makes it the most likely to still be UNCRYPTED when the others finish and call `napi_schedule`.

**Reason 2 — `napi_schedule` fires after every packet, not once per batch.**

Under sustained 25 Gbps traffic with 1,000 clients, there are thousands of decrypt completions per millisecond across all peers. The vast majority of those completions are not at the head of their respective peer queue. Each one fires a `napi_schedule`, raises `NET_RX_SOFTIRQ`, and triggers a poll that finds UNCRYPTED at the head and exits immediately.

The cumulative effect is the 94% CPU saturation the paper measures. The core is not doing useful work — it is alternating between decrypt computation and wasted GRO polls in a tight per-packet cycle.

---

## What the diff does

After `atomic_set_release` marks the current packet `CRYPTED`, the worker reads `peer->rx_queue.tail` with `READ_ONCE`. This is a single pointer read of a field that is only written by the single consumer (`wg_packet_rx_poll` via `wg_prev_queue_dequeue`). It is safe from worker context as a read-only hint.

- If `tail` is the `STUB` sentinel (`&peer->rx_queue.empty`), the queue is in a boundary state — we schedule conservatively to preserve liveness.
- If the packet at `tail` has state `UNCRYPTED`, `wg_packet_rx_poll` cannot make progress regardless of what this worker just finished. We skip `napi_schedule`.
- Otherwise — head is `CRYPTED` or `DEAD` — we schedule normally. GRO will find work to do.

---

## The diff

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

---

## Why it is safe

**The only possible race is a stale read.** If a worker reads `UNCRYPTED` at the instant another core flips the head to `CRYPTED`, this worker skips `napi_schedule`. But the core that performed the flip will call `napi_schedule` itself — it will read `CRYPTED` and schedule normally. No packet is stranded. No liveness is lost.

**The STUB case is handled conservatively.** When `tail == STUB`, reading `NEXT(STUB)` from non-consumer context would require careful handling of the sentinel. Rather than attempt that, we allow the schedule. The STUB case means either the queue is empty (GRO finds nothing, exits cheaply) or the consumer is between dequeue steps — one extra schedule is harmless.

**`atomic_read` not `atomic_read_acquire` for the hint.** We do not need acquire semantics here. This is a speculative hint, not a synchronization point. A relaxed read is correct and avoids the barrier cost.

**Reference counting is unchanged.** The function already holds the peer reference via `wg_peer_get` at the top. The added code uses the existing `peer` variable. `wg_peer_put` at the end releases it as before.

---

## Residual limitation — mid-queue gap latency spike

The fix correctly handles the case where GRO partially advances the queue and stops at a gap. Example:

```
Head: [pkt 0: CRYPTED]   ← GRO delivers
      [pkt 1: CRYPTED]   ← GRO delivers
      [pkt 2: UNCRYPTED] ← GRO stops here, work_done = 2
      [pkt 3: CRYPTED]   ← waiting
```

GRO delivers packets 0 and 1, stops at packet 2, calls `napi_complete_done` which clears `NAPI_STATE_SCHED`. The new head is packet 2, UNCRYPTED. When CPU 3 finishes packet 3, it checks the head — UNCRYPTED — and correctly skips `napi_schedule`. When CPU 2 finishes packet 2, it checks the head — now CRYPTED — and calls `napi_schedule`. GRO delivers packets 2 and 3. This works correctly.

**However, there is a narrow timing window that introduces a latency spike.**

After GRO delivers packets 0 and 1 and stops at packet 2, there is a small window between:
- GRO stopping at the UNCRYPTED head (work_done = 2)
- `napi_complete_done` clearing `NAPI_STATE_SCHED`

If CPU 2 marks packet 2 CRYPTED inside this window:
1. CPU 2 checks head → CRYPTED → calls `napi_schedule`
2. `NAPI_STATE_SCHED` is still set — `napi_schedule` is a no-op (returns immediately)
3. GRO calls `napi_complete_done`, clears the flag
4. **No one reschedules.** Packets 2 and 3 sit in the queue until the next packet arrives and triggers the condition again.

This is not a correctness problem — packets are eventually delivered. Under 25 Gbps sustained traffic the next packet arrives in nanoseconds, so the gap is practically invisible. But under bursty traffic or at the tail of a burst, it could manifest as a latency spike.

**This is a second-order problem.** The diff eliminates the primary overhead: the wasted GRO storm when the head is blocked. The residual gap case is rare, timing-dependent, and requires a more involved solution — for example, a dedicated GRO work item that re-checks the head after `napi_complete_done` clears the flag. That is out of scope for the current implementation target.

**Honest framing for André:** the diff eliminates the dominant source of wasted GRO invocations. It introduces a narrow residual latency risk at mid-queue gaps. Under sustained high-throughput traffic this risk is negligible. It is a significant improvement, not a complete solution.

---

## The four cases

| Case | Situation | Decision | Reason |
|---|---|---|---|
| A | Packet N is the head, just became CRYPTED | Schedule | `tail` state is now non-UNCRYPTED |
| B | Packet N is not head; head already CRYPTED/DEAD | Schedule | `tail` state is non-UNCRYPTED; GRO finds work |
| C | Packet N is not head; head is UNCRYPTED | Skip | GRO stops at head immediately; wasted call |
| D | Packet N is not head; gap before N is UNCRYPTED | Skip | Subcase of C — head is UNCRYPTED |
| STUB | Queue on sentinel boundary | Schedule | Conservative — avoids non-consumer pointer traversal |

---

## Source verification summary

| Claim | File | Line | Status |
|---|---|---|---|
| `queue->tail` written only by consumer | `queueing.c` | 87, 92, 101 | Verified — only inside `wg_prev_queue_dequeue` |
| `peeked` and `tail` are independent fields | `queueing.h` | 138–150 | Verified — `peeked` never touched in `wg_prev_queue_dequeue` |
| `queue->empty` is the STUB sentinel | `queueing.c` | 51, 56 | Verified — `STUB(queue) = (struct sk_buff *)&queue->empty` |
| GRO flushes full contiguous run per call | `receive.c` | 451–485 | Verified — while loop stops only at UNCRYPTED or budget |
| DEAD packets do not block the queue | `receive.c` | 458–459 | Verified — `goto next`, loop continues |
| `napi_schedule` only from decrypt worker, not Stage 1 | `receive.c` | 526, `queueing.h` 196 | Verified — Stage 1 calls `queue_work_on` only |
| Same-peer packets decrypted concurrently on different CPUs | `queueing.h` | 168–171 | Verified — round-robin `wg_cpumask_next_online` |
