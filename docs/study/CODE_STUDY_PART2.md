# Source Investigation — André's Condition
# Session: May 21 afternoon

---

## Block 1 — `wg_packet_rx_poll` behavior (`receive.c:438–491`)

### Q1: Does the loop flush everything up to the first gap in one call?

**YES.** The while loop condition at line 451 is:

```c
while ((skb = wg_prev_queue_peek(&peer->rx_queue)) != NULL &&
       (state = atomic_read_acquire(&PACKET_CB(skb)->state)) !=
               PACKET_STATE_UNCRYPTED) {
    wg_prev_queue_drop_peeked(&peer->rx_queue);
    // ...process...
    if (++work_done >= budget)
        break;
}
```

The loop continues as long as the next packet in queue is **not** UNCRYPTED. It stops only when:
1. It hits an UNCRYPTED packet at the head → stops there, leaves it in queue
2. Queue is empty (`wg_prev_queue_peek` returns NULL)
3. Budget exhausted (`work_done >= budget`)

**Conclusion: a single `wg_packet_rx_poll` call delivers a contiguous run of non-UNCRYPTED packets from the head.** This confirms the hypothesis: GRO either delivers everything it can in one shot, or finds nothing at all.

### Q2: What happens to DEAD packets?

`PACKET_STATE_DEAD != PACKET_STATE_UNCRYPTED`, so DEAD packets **pass the while condition and are consumed**. At line 458:

```c
if (unlikely(state != PACKET_STATE_CRYPTED))
    goto next;   // skip delivery, fall through to free
```

`goto next` skips `wg_packet_consume_data_done` and goes directly to `dev_kfree_skb`. The packet is removed from the queue and freed. **DEAD packets do not block the queue.** They are silently dropped and the loop continues.

This is significant for André's condition: a DEAD packet at the head is fine — GRO can still make progress past it.

### Q3: What is the budget?

WireGuard calls `netif_napi_add(wg->dev, &peer->napi, wg_packet_rx_poll)` at `peer.c:57` without specifying a weight. The kernel default is `NAPI_POLL_WEIGHT = 64`. So the budget passed to each `wg_packet_rx_poll` call is **64 packets**.

### Q4: When is `napi_complete_done` called?

```c
if (work_done < budget)          // line 487
    napi_complete_done(napi, work_done);
```

- **Loop stopped because of UNCRYPTED or empty queue:** `work_done < 64` → `napi_complete_done` called → `NAPI_STATE_SCHED` cleared → NAPI can be scheduled again immediately by the next decrypt worker
- **Loop stopped because budget exhausted:** `work_done == 64` → `napi_complete_done` NOT called → NAPI remains in SCHED state, will be re-called in the next softirq cycle automatically

This is important: if `napi_complete_done` is NOT called, `NAPI_STATE_SCHED` stays set, so any `napi_schedule` call from a decrypt worker is a no-op until the NAPI finishes its budget round.

---

## Block 2 — Queue structure (`queueing.h:138–150`, `queueing.c:80–106`)

### Peek/drop pattern

```c
/* Single consumer */
static inline struct sk_buff *wg_prev_queue_peek(struct prev_queue *queue)
{
    if (queue->peeked)
        return queue->peeked;
    queue->peeked = wg_prev_queue_dequeue(queue);
    return queue->peeked;
}

/* Single consumer */
static inline void wg_prev_queue_drop_peeked(struct prev_queue *queue)
{
    queue->peeked = NULL;
}
```

- `peek` does NOT advance the consumer pointer. It dequeues once from the internal linked list and caches the result in `queue->peeked`. Subsequent peeks return the same cached pointer.
- `drop_peeked` just clears the cache (`peeked = NULL`). The packet is gone from the queue; the next `peek` will dequeue the next one.
- There is no "limbo" state visible to producers. Producers use `xchg_release` on `queue->head` (the producer end). The consumer operates on `queue->tail` (the oldest packet). These are different ends of the linked list — no shared state between peek/drop and enqueue.

### Single consumer guarantee

Both functions are marked `/* Single consumer */`. The only caller of `wg_prev_queue_peek` is `wg_packet_rx_poll` — the NAPI poll function. Since `NAPI_STATE_SCHED` prevents two simultaneous polls for the same peer, the single-consumer invariant is enforced by the NAPI state machine.

**Implication for André's condition:** we cannot safely call `wg_prev_queue_peek` from within `wg_queue_enqueue_per_peer_rx` (the decrypt worker context) without violating the single-consumer guarantee. The `peeked` cache could be corrupted if a NAPI poll is running concurrently on another CPU. The check must use a different mechanism — see Block 4.

### Queue internal structure

The queue uses the `skb->prev` field as the "next" pointer (`#define NEXT(skb) ((skb)->prev)` at `queueing.c:50`). It is a singly-linked list, producer-appends to `head`, consumer-reads from `tail`. The `STUB` sentinel node handles the empty-queue edge case. This is a standard lock-free multi-producer/single-consumer queue pattern.

---

## Block 3 — Packet distribution across CPUs

### The two-phase enqueue (`queueing.h:152–173`)

```c
static inline int wg_queue_enqueue_per_device_and_peer(
    struct crypt_queue *device_queue, struct prev_queue *peer_queue,
    struct sk_buff *skb, struct workqueue_struct *wq)
{
    int cpu;

    atomic_set_release(&PACKET_CB(skb)->state, PACKET_STATE_UNCRYPTED);
    // Phase 1: ordered per-peer queue (determines delivery order)
    if (unlikely(!wg_prev_queue_enqueue(peer_queue, skb)))
        return -ENOSPC;
    // Phase 2: global device ring (determines which CPU decrypts it)
    cpu = wg_cpumask_next_online(&device_queue->last_cpu);
    if (unlikely(ptr_ring_produce_bh(&device_queue->ring, skb)))
        return -EPIPE;
    queue_work_on(cpu, wq, &per_cpu_ptr(device_queue->worker, cpu)->work);
    return 0;
}
```

**Two completely independent queues:**
- `peer->rx_queue` (a `prev_queue`) — FIFO ordered by arrival at Stage 1. Determines delivery order. Packet goes here first, state = UNCRYPTED.
- `wg->decrypt_queue.ring` (a `ptr_ring`) — global across ALL peers, round-robin across CPUs. Determines which CPU decrypts it.

### YES: packets from the same peer are decrypted concurrently on different CPUs

`wg_cpumask_next_online` does approximate round-robin:

```c
static inline int wg_cpumask_next_online(int *last_cpu)
{
    int cpu = cpumask_next(READ_ONCE(*last_cpu), cpu_online_mask);
    // wraps around if past the last CPU
    WRITE_ONCE(*last_cpu, cpu);
    return cpu;
}
```

The comment in `queueing.h:115-119` explicitly says: *"This function is racy, in the sense that it's called while last_cpu is unlocked, so it could return the same CPU twice. Adding locking or using atomic sequence numbers is slower though, and the consequences of racing are harmless."*

So for a peer with 4 consecutive packets arriving at Stage 1:
- Packet 0 → CPU 0 → added to peer->rx_queue (position 0)
- Packet 1 → CPU 1 → added to peer->rx_queue (position 1)
- Packet 2 → CPU 2 → added to peer->rx_queue (position 2)
- Packet 3 → CPU 3 → added to peer->rx_queue (position 3)

All four decrypt in parallel. CPU 2 might finish first, marking position 2 as CRYPTED. Position 0 and 1 are still UNCRYPTED. GRO looks at position 0 → UNCRYPTED → stops. Even though position 2 is ready, GRO cannot reach it.

### The ordering guarantee

Delivery order is guaranteed because:
1. Packets are inserted into `peer->rx_queue` in arrival order (Phase 1 happens before Phase 2)
2. Each packet's state starts as UNCRYPTED atomically (before insertion into peer queue)
3. Workers atomically upgrade state to CRYPTED or DEAD when done
4. `wg_packet_rx_poll` walks from the oldest packet (`queue->tail`) forward, stopping at the first UNCRYPTED

No locks needed — the ordering is established at enqueue time and never changes.

---

## Block 4 — André's condition: the four cases

### What we now know

`wg_packet_rx_poll` flushes **all non-UNCRYPTED packets from the head** in one call. Therefore:

**GRO makes progress if and only if: `peer->rx_queue.tail` (the oldest packet) is NOT UNCRYPTED.**

If the head (oldest) is UNCRYPTED, GRO returns immediately with `work_done = 0`, regardless of what packet N's state is or where it sits in the queue.

### The four cases

Assume packet N just finished decryption and was marked CRYPTED. N is at some position in `peer->rx_queue`. The head is the oldest packet (position 0).

**Case A: Packet N IS the head (position 0)**
- The head just became CRYPTED. GRO can now process it.
- **→ Schedule NAPI. Always.**

**Case B: Packet N is not the head. Head is CRYPTED (or DEAD).**
- GRO was already able to progress from the head before N finished. Scheduling NAPI may deliver a run that now includes N (if all packets between head and N are also non-UNCRYPTED).
- Note: `NAPI_STATE_SCHED` may already be set from a previous worker's `napi_schedule`. In that case, `napi_schedule` is a no-op — harmless but not harmful.
- **→ Schedule NAPI. GRO will find work at the head.**

**Case C: Packet N is not the head. Head is UNCRYPTED.**
- GRO cannot make progress. It will find UNCRYPTED at the head and return immediately regardless of N's state.
- This is the wasted call André's condition eliminates.
- **→ Do NOT schedule NAPI.**

**Case D: Packet N is not the head. Predecessor of N is UNCRYPTED.**
- This is a subcase of Case C — even if N is CRYPTED, there is a gap before N. GRO will stop at the UNCRYPTED head before reaching N.
- **→ Do NOT schedule NAPI.** (Same reason as Case C: checking the head is sufficient.)

### Simplified condition

Cases A and B → trigger. Cases C and D → don't trigger.
The distinguishing test is simply: **is the head of `peer->rx_queue` non-UNCRYPTED?**

André's original intuition about "check the predecessor" is correct in spirit — but checking only the head is actually simpler and fully equivalent. If the head is UNCRYPTED (Cases C and D), GRO fails regardless of what N's predecessor is. If the head is non-UNCRYPTED (Cases A and B), GRO can make progress.

### The implementation problem

**We cannot call `wg_prev_queue_peek` from the worker context.** It is "single consumer" only — calling it from outside the NAPI poll would corrupt the `peeked` cache.

Safe options to check the head state without violating the consumer guarantee:

**Option 1: Direct tail read (careful)**
Read `queue->tail` directly with `READ_ONCE`, then read the state of that skb. This is safe because:
- `queue->tail` is only written by the consumer, but it can be read by others as a hint
- We only need an approximate answer — a stale read that says "UNCRYPTED" when the head just became CRYPTED would cause us to skip one `napi_schedule`, not a correctness problem (the NAPI would be scheduled by the next worker to finish)
- If the tail is the STUB sentinel, the queue is empty → don't schedule

```c
struct sk_buff *head = READ_ONCE(peer->rx_queue.tail);
if (head != (struct sk_buff *)&peer->rx_queue.empty &&
    atomic_read_acquire(&PACKET_CB(head)->state) != PACKET_STATE_UNCRYPTED)
    napi_schedule(&peer->napi);
```

**Option 2: New atomic field on `prev_queue`**
Add an atomic `head_state` field to `struct prev_queue`, updated by the consumer as it processes packets. Workers check this field. Adds memory overhead but is architecturally cleaner.

**Option 3: No check, different fix**
Keep `napi_schedule` unconditional but move GRO to a workqueue (paper's fix) AND add an early exit in `wg_packet_rx_poll` before the budget loop — check the head state atomically and return 0 immediately if UNCRYPTED. This avoids the consumer-violation problem entirely since the check happens inside the consumer itself.

---

## Summary and proposed diff

### Confirmed behavior of `wg_packet_rx_poll`

| Question | Answer | Line |
|---|---|---|
| Loop flushes full contiguous run? | YES — stops only at UNCRYPTED or empty | 451–485 |
| DEAD packets block queue? | NO — consumed and dropped, loop continues | 458–459 |
| Budget | 64 packets (NAPI default) | — |
| napi_complete_done when? | Only when work_done < budget (stopped by gap or empty) | 487–488 |

### Correct trigger condition

```
Schedule NAPI only if: head of peer->rx_queue is NOT UNCRYPTED
```

### Proposed change to `queueing.h:196` (Option 3 — check inside poll)

Rather than modifying the trigger site (which requires accessing the queue from non-consumer context), add a guard at the top of `wg_packet_rx_poll`:

```diff
 int wg_packet_rx_poll(struct napi_struct *napi, int budget)
 {
     struct wg_peer *peer = container_of(napi, struct wg_peer, napi);
+    struct sk_buff *head;
+    enum packet_state head_state;
     ...
     if (unlikely(budget <= 0))
         return 0;
+
+    /* Only proceed if the head packet is ready — otherwise GRO
+     * cannot deliver anything regardless of what follows in the queue.
+     */
+    head = wg_prev_queue_peek(&peer->rx_queue);
+    if (!head || atomic_read_acquire(&PACKET_CB(head)->state) ==
+                        PACKET_STATE_UNCRYPTED) {
+        napi_complete_done(napi, 0);
+        return 0;
+    }
```

This approach:
- Keeps `napi_schedule` unconditional (no consumer-violation problem)
- Eliminates the wasted budget loop entirely when GRO cannot make progress
- `napi_complete_done(napi, 0)` clears `NAPI_STATE_SCHED` so the next decrypt worker's `napi_schedule` can re-arm it
- Stays within the single-consumer guarantee (peek is called only inside `wg_packet_rx_poll`)

### Remaining uncertainties before implementation

1. **Interaction with `peeked` cache:** if the guard peeks and finds UNCRYPTED, `queue->peeked` now holds a pointer to that UNCRYPTED skb. On the next call to `wg_packet_rx_poll`, `wg_prev_queue_peek` will return the same cached pointer (still UNCRYPTED if not yet decrypted) or the state may have changed to CRYPTED. This is correct behavior — the next call re-checks the state.

2. **Is `napi_complete_done(napi, 0)` always correct here?** It clears SCHED and reports 0 packets processed. If the budget was 64 and we return 0, the NAPI machinery treats this as "poll completed with nothing to do." This should be fine — it re-arms the NAPI for future scheduling.

3. **Does this interact with the paper's fix?** If we also move `napi_schedule` to a workqueue (paper's approach), the guard in `wg_packet_rx_poll` still applies — it's orthogonal. Both changes can coexist.

4. **What about the DEAD-at-head case?** A DEAD packet at the head passes the guard (`state != UNCRYPTED`), the poll proceeds, processes the DEAD packet (drops it), and continues to whatever follows. Correct behavior.
