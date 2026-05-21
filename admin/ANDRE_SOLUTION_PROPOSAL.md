# Proposed Fix — Conditional `napi_schedule` in WireGuard RX path
# For review by André Freyssinet

---

## The problem being fixed

`wg_queue_enqueue_per_peer_rx` (`queueing.h:196`) calls `napi_schedule` unconditionally after every decrypted packet. Under concurrent decryption — which is the normal case, since `packet_crypt_wq` is `WQ_PERCPU` and multiple CPUs decrypt packets from the same peer in parallel — the head of `peer->rx_queue` is frequently `UNCRYPTED` while packets at other positions are `CRYPTED`.

`wg_packet_rx_poll` (`receive.c:451`) walks the per-peer RX queue strictly from the head and stops the moment it encounters an `UNCRYPTED` packet. If the head is `UNCRYPTED`, the function returns immediately with `work_done = 0`. Every `napi_schedule` call in this state raises `NET_RX_SOFTIRQ`, which fires at the next `spin_unlock_bh` inside `ptr_ring_consume_bh` of the decrypt worker's own loop — preempting the worker and running a poll that delivers zero packets. This is the EoI overhead.

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
