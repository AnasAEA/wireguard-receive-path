# EoI Proof — Source Code Walk-Through
# Meeting with Alain & André — Thursday May 21, 9h

> Line-by-line source code evidence for the Execution Order Inversion in WireGuard's kernel receive pipeline.
> All files are in `linux-source/` in the repository.

---

## The claim

WireGuard's Stage 2 decrypt workers (running at `SCHED_NORMAL`) repeatedly schedule Stage 3 (GRO softirq, running at BH priority) before the data Stage 3 needs is ready. Stage 3 preempts Stage 2, finds nothing to process, and aborts — wasting CPU cycles. This is the primary cause of the 19.2% throughput ceiling measured in the paper.

---

## Step 1 — Each peer has its own NAPI instance

**File:** `peer.c:56–58`

```c
set_bit(NAPI_STATE_NO_BUSY_POLL, &peer->napi.state);
netif_napi_add(wg->dev, &peer->napi, wg_packet_rx_poll);  // ← registers poll function
napi_enable(&peer->napi);
```

Every peer gets its own `napi_struct` at creation. `netif_napi_add` links `peer->napi` to the poll function `wg_packet_rx_poll`. From this point, calling `napi_schedule(&peer->napi)` anywhere in the code will schedule `wg_packet_rx_poll` for that specific peer.

With 1,000 peers: 1,000 independent NAPI instances, each capable of triggering its own GRO fire.

---

## Step 2 — The decrypt workqueue is per-CPU, SCHED_NORMAL

**File:** `device.c:346–347`

```c
wg->packet_crypt_wq = alloc_workqueue("wg-crypt-%s",
        WQ_CPU_INTENSIVE | WQ_MEM_RECLAIM | WQ_PERCPU, 0, dev->name);
```

`WQ_PERCPU` — one worker thread pinned per CPU. Each CPU has exactly one decrypt worker.

`WQ_CPU_INTENSIVE` — workers are excluded from the kernel's concurrency throttle (they don't count toward `nr_running`). This is appropriate because the workers are pure CPU computation — but it does NOT prevent them from being preempted by softirqs.

Workers run at `SCHED_NORMAL` — the same scheduling class as a regular user process. **Softirqs (BH) always preempt `SCHED_NORMAL` threads.**

---

## Step 3 — The decrypt worker loop

**File:** `receive.c:493–507`

```c
void wg_packet_decrypt_worker(struct work_struct *work)
{
    struct crypt_queue *queue = container_of(work, struct multicore_worker, work)->ptr;
    struct sk_buff *skb;

    while ((skb = ptr_ring_consume_bh(&queue->ring)) != NULL) {
        enum packet_state state =
            likely(decrypt_packet(skb, PACKET_CB(skb)->keypair)) ?
                PACKET_STATE_CRYPTED : PACKET_STATE_DEAD;
        wg_queue_enqueue_per_peer_rx(skb, state);   // ← EoI trigger is inside here
        if (need_resched())
            cond_resched();
    }
}
```

Each iteration:
1. Pull one encrypted packet from the global ring
2. Decrypt it (ChaCha20-Poly1305 — pure CPU, no locks)
3. Hand it off to the per-peer receive queue and schedule GRO

---

## Step 4 — `ptr_ring_consume_bh`: the BH disable/enable cycle

**File:** `include/linux/ptr_ring.h:371`

```c
static inline void *ptr_ring_consume_bh(struct ptr_ring *r)
{
    void *ptr;
    spin_lock_bh(&r->consumer_lock);    // ① BH disabled — softirqs cannot fire
    ptr = __ptr_ring_consume(r);        // ② pull packet from ring
    spin_unlock_bh(&r->consumer_lock);  // ③ BH re-enabled → local_bh_enable()
    return ptr;                         // ④ if any softirq was pending, it fired in ③
}
```

**Key point:** BH is disabled only during the ring access (①–③). After `ptr_ring_consume_bh` returns, BH is re-enabled. `spin_unlock_bh` calls `local_bh_enable()` — if any softirq is pending at that moment, it fires immediately before the function returns to the caller.

---

## Step 5 — The EoI trigger: `wg_queue_enqueue_per_peer_rx`

**File:** `queueing.h:188–197`

```c
static inline void wg_queue_enqueue_per_peer_rx(struct sk_buff *skb,
                                                  enum packet_state state)
{
    struct wg_peer *peer = wg_peer_get(PACKET_PEER(skb));
    atomic_set_release(&PACKET_CB(skb)->state, state);  // ① mark packet CRYPTED
    napi_schedule(&peer->napi);                         // ② schedule GRO — EoI trigger
    wg_peer_put(peer);
}
```

**① `atomic_set_release(CRYPTED)`** — the just-decrypted packet IS marked as ready before `napi_schedule` is called. This is important: GRO does not fail because this packet isn't ready.

**② `napi_schedule(&peer->napi)`** — this raises the NET_RX_SOFTIRQ flag but does NOT fire it immediately. The softirq will fire at the next `local_bh_enable()`.

---

## Step 6 — `napi_schedule`: CPU binding

**File:** `net/core/dev.c:6710`

```c
void __napi_schedule(struct napi_struct *n)
{
    unsigned long flags;
    local_irq_save(flags);
    ____napi_schedule(this_cpu_ptr(&softnet_data), n);  // ← binds to THIS CPU
    local_irq_restore(flags);
}
```

**File:** `net/core/dev.c:4957`

```c
static inline void ____napi_schedule(struct softnet_data *sd,
                                      struct napi_struct *napi)
{
    list_add_tail(&napi->poll_list, &sd->poll_list);  // added to THIS CPU's poll list
    __raise_softirq_irqoff(NET_RX_SOFTIRQ);           // flag raised, not yet fired
}
```

`this_cpu_ptr(&softnet_data)` captures the CPU executing `napi_schedule` at that instant. The NAPI poll is bound to that CPU's poll list. Once bound, `NAPI_STATE_SCHED` is set — any subsequent `napi_schedule` call from any CPU is a **no-op** until the poll completes.

---

## Step 7 — When the softirq fires

The softirq fires at the `spin_unlock_bh` inside `ptr_ring_consume_bh` of the **next loop iteration**:

```
Iteration N:
  ptr_ring_consume_bh()         → BH re-enabled after getting packet N
  decrypt_packet(pkt N)         → pure crypto
  wg_queue_enqueue_per_peer_rx()
    atomic_set_release(CRYPTED) → pkt N marked ready
    napi_schedule()             → NET_RX_SOFTIRQ raised, not yet fired

Iteration N+1:
  ptr_ring_consume_bh()
    spin_lock_bh()              → BH disabled
    __ptr_ring_consume()        → pull packet N+1
    spin_unlock_bh()
      local_bh_enable()
        do_softirq()
          NET_RX_SOFTIRQ        → wg_packet_rx_poll() fires HERE ←
```

GRO fires inside `ptr_ring_consume_bh`, after pulling packet N+1 but before the worker's loop body runs for N+1.

---

## Step 8 — Why GRO finds nothing: the ordering constraint

**File:** `receive.c:451–453`

```c
while ((skb = wg_prev_queue_peek(&peer->rx_queue)) != NULL &&
       (state = atomic_read_acquire(&PACKET_CB(skb)->state)) !=
               PACKET_STATE_UNCRYPTED) {
```

`wg_packet_rx_poll` walks the per-peer RX queue **strictly from the head** and stops the moment it encounters an `UNCRYPTED` packet. It cannot skip ahead.

Under concurrent load, the queue looks like:

```
Head: [pkt 0: UNCRYPTED]  ← Worker 0 is still decrypting this
      [pkt 1: CRYPTED]    ← Worker 1 just finished, called napi_schedule
      [pkt 2: UNCRYPTED]  ← Worker 2 still working
      ...
```

GRO peeks at the head → pkt 0 is `UNCRYPTED` → exits immediately. `work_done = 0`. The CPU cycle is entirely wasted. The ordering constraint exists because TCP requires in-order delivery — GRO cannot deliver pkt 1 before pkt 0.

---

## Step 9 — Self-reinforcing saturation

With `WQ_PERCPU`, the decrypt worker on CPU X is pinned to CPU X. GRO also fires on CPU X (bound there by `napi_schedule`). The cycle on CPU X:

```
decrypt worker runs  →  calls napi_schedule  →  GRO fires (preempts worker)
  →  GRO finds nothing (ordering constraint)  →  GRO returns
  →  worker resumes, calls ptr_ring_consume_bh for next packet
  →  spin_unlock_bh triggers GRO again  →  ...
```

CPU X alternates between decrypt work and wasted GRO fires. The paper measures this as 94% CPU utilization on the saturated core with only 19.2% of expected throughput — the core is busy but mostly doing useless GRO polls.

---

## Complete chain — files and lines

| Step | File | Line | What happens |
|---|---|---|---|
| Peer NAPI created | `peer.c` | 57 | `netif_napi_add(wg->dev, &peer->napi, wg_packet_rx_poll)` |
| Workqueue created | `device.c` | 346 | `packet_crypt_wq` — `WQ_CPU_INTENSIVE\|WQ_PERCPU` |
| Worker dispatched | `queueing.c` | 9 | `INIT_WORK` per CPU → `queue_work_on` |
| Decrypt worker loop | `receive.c` | 493 | `ptr_ring_consume_bh` → `decrypt_packet` → `wg_queue_enqueue_per_peer_rx` |
| BH timing | `ptr_ring.h` | 371 | `spin_unlock_bh` → `local_bh_enable` → softirq fires |
| Packet marked ready | `queueing.h` | 195 | `atomic_set_release(CRYPTED)` — before `napi_schedule` |
| EoI trigger | `queueing.h` | 196 | `napi_schedule(&peer->napi)` — raises NET_RX_SOFTIRQ |
| CPU binding | `net/core/dev.c` | 4957 | `this_cpu_ptr(&softnet_data)` — NAPI bound to current CPU |
| GRO fires | `ptr_ring.h` | 371 | At `spin_unlock_bh` of next `ptr_ring_consume_bh` call |
| Ordering constraint | `receive.c` | 451 | `wg_packet_rx_poll` stops at first UNCRYPTED head |
| Wasted cycle | `receive.c` | 487 | `work_done = 0` → `napi_complete_done` → NAPI_STATE_SCHED cleared |

---

## What the fix does (from the paper)

The paper's fix moves GRO out of the softirq path — instead of calling `napi_schedule` (which binds GRO to the current CPU's softirq context), it dispatches GRO to a dedicated workqueue that runs on a separate CPU. This breaks the tight coupling between the decrypt worker and GRO, eliminating the preemption cycle.

Result: 4.7× throughput increase, 46% tail latency reduction.
