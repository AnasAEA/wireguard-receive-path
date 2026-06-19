# Code Study Notes — WireGuard kernel receive pipeline
# Anas Ait El Hadj · May 2026

> Running notes from reading the actual kernel source.
> Every claim here has a file:line citation.
> This feeds into the meeting with Alain and André (week of May 19).

---

## Sources used

| Repo / file | How obtained | Version |
|---|---|---|
| `linux-source/drivers/net/wireguard/` | curl from `WireGuard/wireguard-linux` `devel` branch | current devel |
| `linux-source/kernel/workqueue.c` | curl from `torvalds/linux` master | current master |

---

## Part 1 — WireGuard reception pipeline

### Files read
- `drivers/net/wireguard/receive.c` (586 lines)
- `drivers/net/wireguard/device.c` (475 lines)
- `drivers/net/wireguard/queueing.h` (key inline functions)

---

### Background concepts needed to understand EoI

Before reading the code, three kernel mechanisms must be understood clearly.

#### What is a softirq / BH (Bottom Half)?

When a network packet arrives at a NIC, the NIC raises a hardware interrupt. The kernel has a rule: interrupt handlers must be as short as possible — they should not do heavy work like processing the entire packet. So the kernel splits network processing into two halves:

- **Top half** (hardware interrupt): runs immediately when the NIC signals. It does the minimum — tells the kernel "a packet arrived", saves a pointer, and exits. This runs with ALL interrupts disabled on the current CPU.
- **Bottom half** (softirq): runs shortly after. It does the real packet processing — parsing, routing, passing to TCP/IP, etc. This runs with normal interrupts re-enabled but with other softirqs disabled on the current CPU.

"BH" stands for Bottom Half. It is used interchangeably with "softirq" in the kernel code and docs.

The key property: **softirqs (BH) preempt normal kernel threads**. A normal process or workqueue worker runs at `SCHED_NORMAL` priority. When a softirq becomes pending and BH is re-enabled, the softirq fires immediately and takes over the CPU — the normal thread is suspended until the softirq finishes.

The kernel controls when softirqs can fire with two operations:
- `local_bh_disable()` — prevents softirqs from firing on this CPU (they are deferred)
- `local_bh_enable()` — re-enables softirqs; if any are pending, they fire immediately

Spinlocks with the `_bh` suffix (`spin_lock_bh` / `spin_unlock_bh`) call these internally:
```c
spin_lock_bh(lock)   =  local_bh_disable() + spin_lock(lock)
spin_unlock_bh(lock) =  spin_unlock(lock) + local_bh_enable()
                                            ↑ softirqs fire here if pending
```

#### What is NAPI?

NAPI (New API) is the Linux mechanism for receiving network packets efficiently under high load. Instead of an interrupt per packet (which would flood the CPU), NAPI works like this:

1. The first packet triggers a hardware interrupt
2. The interrupt handler disables further NIC interrupts and schedules a **NAPI poll**
3. The kernel later runs the poll function, which reads as many packets as possible in one go (up to a `budget`)
4. When the poll is done, NIC interrupts are re-enabled

The poll function runs as a **NET_RX_SOFTIRQ** — a specific softirq for network receive. This means it runs at BH priority, higher than normal kernel threads.

In WireGuard, NAPI is used unconventionally. WireGuard is not a physical NIC — it's a virtual tunnel. It does not receive packets from hardware. Instead, it uses NAPI as a scheduling mechanism to pass decrypted packets up the network stack. Each peer has its own `napi_struct` (`peer->napi`), and WireGuard calls `napi_schedule` to trigger the poll function after decryption is done.

WireGuard's NAPI poll function is `wg_packet_rx_poll` at `receive.c:438`. It does not talk to hardware — it reads from an in-memory per-peer queue of decrypted packets and passes them to the kernel networking layer via `napi_gro_receive`.

**GRO** (Generic Receive Offload) is a sub-mechanism inside NAPI that coalesces multiple small TCP segments into fewer large ones before handing them to the network stack, improving efficiency. In this context, "GRO fires" means the NAPI poll function runs.

#### What is EoI (Execution Order Inversion)?

EoI (also called priority inversion in some contexts) is what happens when a low-priority task schedules a high-priority task, and the high-priority task then preempts the low-priority task before the low-priority task has finished setting things up.

In WireGuard:
- Stage 2 (decryption) is the low-priority task — workqueue worker at `SCHED_NORMAL`
- Stage 3 (GRO/NAPI) is the high-priority task — softirq

The inversion: Stage 2 calls `napi_schedule` (scheduling Stage 3) while Stage 2 is still running. Stage 3 then fires and preempts Stage 2. Stage 3 finds the work it expected to be done is not ready (because Stage 2 was preempted before finishing). Stage 3 aborts. Stage 2 resumes and finishes. Stage 3 fires again. This double-firing wastes CPU time and increases latency.

---

### 1.1 The decryption workqueue — `packet_crypt_wq`

**File:** `device.c:346–347`

```c
wg->packet_crypt_wq = alloc_workqueue("wg-crypt-%s",
        WQ_CPU_INTENSIVE | WQ_MEM_RECLAIM | WQ_PERCPU, 0, dev->name);
```

**Flags:**
- `WQ_CPU_INTENSIVE` — workers from this queue are excluded from the kernel's per-CPU concurrency accounting. The kernel normally limits how many workqueue workers run simultaneously on a CPU. `WQ_CPU_INTENSIVE` says "don't count us — we intentionally hog the CPU for computation." This allows other work items to be run alongside. (It does NOT mean workers are prevented from blocking — see Part 6.)
- `WQ_MEM_RECLAIM` — creates a dedicated rescue worker thread. If all normal workers are stuck waiting for memory allocation, the rescue worker can always run to make progress. Relevant for correctness, not throughput.
- `WQ_PERCPU` — one worker thread per CPU, each pinned to its CPU via `queue_work_on(cpu, wq, work)`. Workers do not float between CPUs the way `WQ_UNBOUND` workers do.

**Note on WQ_PERCPU:** Our earlier claim that WireGuard uses `WQ_UNBOUND` workers is wrong. It's per-CPU. This matters: each CPU has exactly one decrypt worker, pinned to it.

Other workqueues in `device.c`:
- `handshake_receive_wq` → `WQ_CPU_INTENSIVE | WQ_FREEZABLE | WQ_PERCPU` (line 335–336)
- `handshake_send_wq` → `WQ_UNBOUND | WQ_FREEZABLE` (line 341–342)

The decryption path — `packet_crypt_wq` — is the one relevant to EoI and to the paper's results.

### 1.2 The decryption worker function

**File:** `receive.c:493–507`

```c
void wg_packet_decrypt_worker(struct work_struct *work)
{
    struct crypt_queue *queue = container_of(work, struct multicore_worker,
                         work)->ptr;
    struct sk_buff *skb;

    while ((skb = ptr_ring_consume_bh(&queue->ring)) != NULL) {
        enum packet_state state =
            likely(decrypt_packet(skb, PACKET_CB(skb)->keypair)) ?
                PACKET_STATE_CRYPTED : PACKET_STATE_DEAD;
        wg_queue_enqueue_per_peer_rx(skb, state);
        if (need_resched())
            cond_resched();
    }
}
```

This is Stage 2. It runs inside `packet_crypt_wq` at `SCHED_NORMAL` priority — the same priority as a regular user-space process. It has no special privileges over softirqs.

`ptr_ring_consume_bh` pulls one packet from the per-device decryption ring. Internally:

```c
// from include/linux/ptr_ring.h
static inline void *ptr_ring_consume_bh(struct ptr_ring *r)
{
    void *ptr;
    spin_lock_bh(&r->consumer_lock);    // ① disables BH (softirqs cannot fire)
    ptr = __ptr_ring_consume(r);        // ② pulls one packet from the ring
    spin_unlock_bh(&r->consumer_lock);  // ③ re-enables BH → if any softirq is pending, it fires HERE
    return ptr;                         // ④ returns the packet
}
```

The critical point: **BH is disabled only briefly during the ring access** (steps ①–③). After `ptr_ring_consume_bh` returns, BH is re-enabled and the worker runs `decrypt_packet` and `wg_queue_enqueue_per_peer_rx` with BH enabled.

### 1.3 EoI trigger — `wg_queue_enqueue_per_peer_rx`

**File:** `queueing.h:188–197`

```c
static inline void wg_queue_enqueue_per_peer_rx(struct sk_buff *skb,
                                                 enum packet_state state)
{
    struct wg_peer *peer = wg_peer_get(PACKET_PEER(skb));
    atomic_set_release(&PACKET_CB(skb)->state, state);  // ← marks packet CRYPTED
    napi_schedule(&peer->napi);                         // ← EoI trigger
    wg_peer_put(peer);
}
```

**Step 1 — Mark the packet as decrypted:**

`atomic_set_release` sets `PACKET_CB(skb)->state` to `PACKET_STATE_CRYPTED`. This is an atomic store with release semantics — it is visible to all CPUs immediately. The packet IS marked as ready before `napi_schedule` is called. This is important for correcting a common misunderstanding below.

**Step 2 — `napi_schedule(&peer->napi):`**

```c
// from net/core/dev.c
void __napi_schedule(struct napi_struct *n)
{
    unsigned long flags;
    local_irq_save(flags);                              // disable IRQs briefly
    ____napi_schedule(this_cpu_ptr(&softnet_data), n); // bind NAPI to this CPU
    local_irq_restore(flags);
}

static inline void ____napi_schedule(struct softnet_data *sd,
                                     struct napi_struct *napi)
{
    list_add_tail(&napi->poll_list, &sd->poll_list);   // add to THIS CPU's poll list
    __raise_softirq_irqoff(NET_RX_SOFTIRQ);            // mark NET_RX softirq as pending
}
```

What `napi_schedule` does:
1. **Binds the NAPI poll to the current CPU.** `this_cpu_ptr(&softnet_data)` gets the softnet_data of the CPU executing this line right now. The NAPI poll function (`wg_packet_rx_poll`) is added to that CPU's poll list. This is the "stale binding" — see below.
2. **Raises the NET_RX_SOFTIRQ flag.** This marks a softirq as pending, but does NOT fire it immediately. The softirq fires at the next `local_bh_enable()`.

**Why doesn't the softirq fire immediately?** After `napi_schedule` returns, we are in the body of the while loop with BH already enabled. `napi_schedule` internally uses `local_irq_save/restore` (disabling hardware interrupts, not BH). There is no `local_bh_enable()` call in the loop body between `napi_schedule` and the next `ptr_ring_consume_bh`. So the softirq stays pending.

**When does it fire?** At the next call to `ptr_ring_consume_bh` for the next packet:
- `spin_lock_bh` → disables BH
- `__ptr_ring_consume` → gets next packet
- `spin_unlock_bh` → re-enables BH → `local_bh_enable()` → **NET_RX_SOFTIRQ fires here**

GRO (the NAPI poll) then runs on this CPU, interrupting the worker before it can process the next packet.

### 1.4 Why GRO finds nothing — the ordering constraint

**File:** `receive.c:451–453` inside `wg_packet_rx_poll`

```c
while ((skb = wg_prev_queue_peek(&peer->rx_queue)) != NULL &&
       (state = atomic_read_acquire(&PACKET_CB(skb)->state)) !=
               PACKET_STATE_UNCRYPTED) {   // ← stops at first UNCRYPTED head
```

`wg_packet_rx_poll` walks the per-peer RX queue **strictly from the head** and stops the moment it sees a packet that is still `PACKET_STATE_UNCRYPTED`. It cannot skip ahead to process later ready packets. This is intentional: packets must be delivered to the network stack in the order they were received (TCP relies on this).

Here is the scenario under concurrent load (e.g., 8 CPUs, 8 workers, many packets):

```
Per-peer RX queue (ordered by receive time):
  Head: [pkt 0: UNCRYPTED]  ← being decrypted by Worker 0
        [pkt 1: CRYPTED]    ← Worker 1 just finished, called napi_schedule
        [pkt 2: UNCRYPTED]  ← being decrypted by Worker 2
        [pkt 3: CRYPTED]    ← done
        ...                 (tail)
```

Worker 1 just called `napi_schedule` and marked pkt 1 as CRYPTED. At the next `ptr_ring_consume_bh` call, GRO fires:

1. GRO calls `wg_packet_rx_poll`
2. Peeks at head of queue: pkt 0 → state = `UNCRYPTED` → **stops immediately**
3. `work_done = 0` — nothing was processed
4. GRO returns. The CPU cycle is wasted.

Note the important correction from earlier documentation: **the just-decrypted packet (pkt 1) IS already marked CRYPTED** before `napi_schedule` is called. GRO doesn't fail because pkt 1 isn't ready — it fails because pkt 0 (ahead in the queue) is not ready. GRO cannot skip pkt 0 to process pkt 1.

This wasted GRO firing is the EoI: a high-priority task (GRO softirq) runs but accomplishes nothing, stealing CPU time from the low-priority tasks (decrypt workers) that are doing actual useful work.

**Remark — DEAD packets are not a blocking condition.**

`PACKET_STATE_DEAD` (set when `decrypt_packet` returns false — e.g., authentication tag mismatch) does NOT stop the loop. The while condition only exits on `PACKET_STATE_UNCRYPTED`. A DEAD packet satisfies `DEAD != UNCRYPTED`, so it enters the loop body, hits `receive.c:458`:

```c
if (unlikely(state != PACKET_STATE_CRYPTED))
    goto next;   // skips processing, frees the skb
```

and is freed. The loop then advances to the next packet. A DEAD packet at the head does not create the EoI blockage — only an UNCRYPTED one does. This is consistent with the EoI being a normal-path problem (every burst of packets triggers it), not an error-path problem.

### 1.5 The stale CPU binding — self-reinforcing saturation

`napi_schedule` uses `this_cpu_ptr(&softnet_data)` — it binds the NAPI poll to whatever CPU is executing `napi_schedule` at that moment. This is a snapshot, not a live reference.

The binding is persistent: once NAPI is added to CPU X's poll list, `NAPI_STATE_SCHED` is set on `peer->napi`. Any subsequent `napi_schedule` call from any CPU is a **no-op** — `napi_schedule_prep` checks `NAPI_STATE_SCHED` and returns false if it's already set. The NAPI stays bound to CPU X until `napi_complete_done` clears the flag after the poll finishes.

Under high load, the self-reinforcing loop:

```
1. Worker on CPU X calls napi_schedule → NAPI bound to CPU X
2. At next ptr_ring_consume_bh, GRO fires on CPU X
3. GRO finds nothing (ordering constraint), aborts
4. napi_complete_done clears NAPI_STATE_SCHED
5. Worker on CPU X (or another CPU) finishes next packet, calls napi_schedule again
   → NAPI re-bound to whichever CPU happens to call it this time
6. GRO fires again → same outcome
```

With WQ_PERCPU (each CPU has its own decrypt worker), the worker on CPU X is pinned there. GRO also fires on CPU X. GRO (softirq) preempts the worker. The worker is suspended. GRO finds nothing. Worker resumes. Then immediately: worker calls `ptr_ring_consume_bh` for the next packet → triggers GRO again. CPU X is saturated with an alternating worker/GRO cycle that makes little forward progress.

The paper measures this as 94% CPU utilization on the saturated core with only 19.2% of expected throughput.

### 1.6 Complete corrected EoI chain

```
Iteration N:
─────────────────────────────────────────────────────────────────
ptr_ring_consume_bh()              receive.c:499
  spin_lock_bh()                   BH disabled
  __ptr_ring_consume()             pull packet N from ring
  spin_unlock_bh()                 BH re-enabled
                                   ← if any softirq was pending from
                                      iteration N-1, it fires HERE

[BH is NOW enabled for loop body]

decrypt_packet(skb)                receive.c:501
  chacha20poly1305_decrypt_...     pure CPU crypto, no BH transitions

wg_queue_enqueue_per_peer_rx()     receive.c:503
  atomic_set_release(CRYPTED)      queueing.h:195  ← packet N marked READY
  napi_schedule(&peer->napi)       queueing.h:196
    local_irq_save()               IRQs briefly disabled (NOT BH)
    list_add_tail(napi, cpu_poll)  bind NAPI to this CPU's poll list
    __raise_softirq(NET_RX)        mark softirq as pending — does NOT fire yet
    local_irq_restore()            IRQs restored; BH still enabled
                                   ← softirq is pending but won't fire until
                                      next local_bh_enable()

need_resched() / cond_resched()    possible yield, no BH transitions

─────────────────────────────────────────────────────────────────
Iteration N+1:
─────────────────────────────────────────────────────────────────
ptr_ring_consume_bh()              receive.c:499
  spin_lock_bh()                   BH disabled (pending softirq deferred)
  __ptr_ring_consume()             pull packet N+1 from ring
  spin_unlock_bh()                 BH re-enabled
    local_bh_enable()
      do_softirq()
        NET_RX_SOFTIRQ handler
          wg_packet_rx_poll()      receive.c:438   ← GRO fires HERE
            peek head of rx_queue
            if head.state == UNCRYPTED → return 0  ← finds nothing, aborts
            (ordering constraint: can't skip to packet N which is CRYPTED)
  return packet N+1                ptr_ring_consume_bh returns
[worker resumes: decrypt packet N+1, then triggers GRO again ...]
```

### 1.7 NAPI poll handler — `wg_packet_rx_poll`

**File:** `receive.c:438–491`

```c
int wg_packet_rx_poll(struct napi_struct *napi, int budget)
{
    struct wg_peer *peer = container_of(napi, struct wg_peer, napi);
    // ...
    while ((skb = wg_prev_queue_peek(&peer->rx_queue)) != NULL &&
           (state = atomic_read_acquire(&PACKET_CB(skb)->state)) !=
                   PACKET_STATE_UNCRYPTED) {
        wg_prev_queue_drop_peeked(&peer->rx_queue);
        // ...
        wg_packet_consume_data_done(peer, skb, &endpoint);  // calls napi_gro_receive
        // ...
        if (++work_done >= budget) break;
    }
    if (work_done < budget)
        napi_complete_done(napi, work_done);   // receive.c:488 — clears NAPI_STATE_SCHED
    return work_done;
}
```

This is Stage 3. It runs at softirq (BH) priority — higher than the workqueue workers running at `SCHED_NORMAL`. Every time it fires during heavy decryption, it preempts Stage 2.

The stopping condition `state != PACKET_STATE_UNCRYPTED` is what creates the ordering constraint. The poll stops at the first packet that isn't ready yet, even if later packets in the queue are already decrypted.

`napi_complete_done` at line 488 clears `NAPI_STATE_SCHED`, allowing `napi_schedule` to re-bind the NAPI on the next call.

### 1.8 How packets enter the decryption workqueue

**File:** `receive.c:524–529` inside `wg_packet_consume_data()`

```c
ret = wg_queue_enqueue_per_device_and_peer(
        &wg->decrypt_queue, &peer->rx_queue, skb,
        wg->packet_crypt_wq);
```

This does two things simultaneously:
1. Adds the skb to the **per-device** global decrypt queue (from which `wg_packet_encrypt_worker` pulls in parallel)
2. Adds the skb to the **per-peer** ordered RX queue (from which `wg_packet_rx_poll` reads in order)

The packet's initial state is `PACKET_STATE_UNCRYPTED`. The NAPI poll can see it immediately but will stop on it. Only after `decrypt_packet` runs and `atomic_set_release(CRYPTED)` is called does the NAPI poll move past it.

### 1.9 Where `peer->napi` comes from — `wg_peer_create`

**File:** `peer.c:21–69`

#### When is this called?

`wg_peer_create` is called at **configuration time** — when an administrator adds a peer via `wg set` or `wg-quick up`. This is not in the data path. Each WireGuard peer (each remote endpoint the tunnel communicates with) gets its own `wg_peer` struct, and inside that struct, its own `napi_struct`.

#### What is `napi_struct`?

`napi_struct` is the kernel's representation of one NAPI polling context. From `include/linux/netdevice.h:381`:

```c
struct napi_struct {
    unsigned long       state;       // bitfield: SCHED, DISABLE, MISSED, NO_BUSY_POLL, ...
    struct list_head    poll_list;   // node in a CPU's softnet_data.poll_list
    int                 weight;      // max packets to process per poll (budget)
    int                 (*poll)(struct napi_struct *, int);  // the poll function
    int                 list_owner;  // which CPU currently owns this NAPI (-1 = none)
    struct net_device  *dev;         // associated network device
    struct gro_node     gro;         // GRO coalescing state
    u32                 napi_id;     // unique identifier
    // ...
};
```

The key fields for the EoI analysis:
- **`poll`** — function pointer set to `wg_packet_rx_poll` at registration. This is what runs when the NAPI fires.
- **`poll_list`** — the node used to insert this NAPI into a CPU's `softnet_data.poll_list`. When `napi_schedule` is called, it inserts this node into the current CPU's list.
- **`state`** — a bitfield controlling whether the NAPI can be scheduled, is currently scheduled, is disabled, etc.
- **`weight`** — the maximum number of packets to process per invocation (`NAPI_POLL_WEIGHT`, typically 64). This is the `budget` parameter passed to `wg_packet_rx_poll`.
- **`list_owner`** — initialized to -1. Records which CPU currently has this NAPI in its poll list. Important: this is distinct from `this_cpu_ptr` used in `napi_schedule` — the ownership tracking is separate from the binding mechanism.

#### The three setup lines

```c
set_bit(NAPI_STATE_NO_BUSY_POLL, &peer->napi.state);      // peer.c:56
netif_napi_add(wg->dev, &peer->napi, wg_packet_rx_poll);  // peer.c:57
napi_enable(&peer->napi);                                  // peer.c:58
```

**Line 56 — `NAPI_STATE_NO_BUSY_POLL`:**

This flag is set **before** `netif_napi_add` so that when `netif_napi_add` internally calls `napi_hash_add`, this NAPI is excluded from the busy-poll hash table.

Busy polling (`SO_BUSY_POLL` socket option) is an optimization for hardware NICs: instead of waiting for an interrupt, user-space spins on the socket, and the kernel polls the NIC directly in a tight loop. This reduces latency but burns CPU. It only makes sense for real hardware NICs.

WireGuard is a virtual tunnel — there is no hardware to poll. Setting `NAPI_STATE_NO_BUSY_POLL` tells the kernel: "do not register this NAPI in the busy-poll hash; do not attempt to busy-poll it." Without this flag, a user-space process using `SO_BUSY_POLL` might try to poll WireGuard's NAPI directly, which would be meaningless and wasteful.

**Line 57 — `netif_napi_add`:**

This is the full NAPI registration call. Internally (`net/core/dev.c:7558`):

```c
void netif_napi_add_weight_locked(struct net_device *dev,
                                   struct napi_struct *napi,
                                   int (*poll)(struct napi_struct *, int),
                                   int weight)
{
    // Guard: set NAPI_STATE_LISTED atomically — prevents double registration
    if (WARN_ON(test_and_set_bit(NAPI_STATE_LISTED, &napi->state)))
        return;

    INIT_LIST_HEAD(&napi->poll_list);          // initialize the list node
    gro_init(&napi->gro);                      // initialize GRO state
    napi->poll = poll;                         // store wg_packet_rx_poll here
    napi->weight = weight;                     // NAPI_POLL_WEIGHT (64)
    napi->dev = dev;                           // link to WireGuard's net_device
    napi->list_owner = -1;                     // not owned by any CPU yet

    set_bit(NAPI_STATE_SCHED, &napi->state);   // mark as "scheduled" — not yet runnable
    set_bit(NAPI_STATE_NPSVC, &napi->state);   // mark as "not in service" — blocks scheduling

    netif_napi_dev_list_add(dev, napi);        // add to device's NAPI list
    // ...
}
```

After `netif_napi_add`, the NAPI exists in the system and has its poll function set, but it is **not yet schedulable** — both `NAPI_STATE_SCHED` and `NAPI_STATE_NPSVC` are set, which means `napi_schedule_prep` would return false. The `NAPI_STATE_SCHED` bit being set here is a "pre-armed disabled" state, not an actual schedule.

**Line 58 — `napi_enable`:**

`napi_enable` is a simple activation gate. Before it is called, the NAPI instance exists in memory but is deliberately locked out from being scheduled. After it is called, the NAPI is live and `napi_schedule` can add it to a CPU's poll list.

```c
void napi_enable(struct napi_struct *n)
{
    BUG_ON(!test_bit(NAPI_STATE_SCHED, &n->state));
    clear_bit(NAPI_STATE_SCHED, &n->state);
    clear_bit(NAPI_STATE_NPSVC, &n->state);
}
```

- `NAPI_STATE_SCHED` — set artificially at init to mean "disabled"; clearing it makes the NAPI schedulable
- `NAPI_STATE_NPSVC` — marks the disabled/in-service state; clearing it signals the NAPI is operational

**Why the gate exists:** the peer struct might not be fully initialized when `netif_napi_add` registers the NAPI with the device. `napi_enable` at `peer.c:58` says "setup is complete, safe to schedule."

**`napi_disable` — the symmetric counterpart:** sets `NAPI_STATE_SCHED` back and busy-waits until any currently running poll (`wg_packet_rx_poll`) finishes. Unlike `napi_enable`, it can sleep. Used during peer teardown (`peer.c:120`) to guarantee no poll is in flight before freeing the peer's memory.

**WireGuard sequence at peer creation (`wg_peer_create`):**
1. `netif_napi_add` — registers `wg_packet_rx_poll`, initializes GRO state, sets SCHED+NPSVC (disabled)
2. `napi_enable` — clears SCHED+NPSVC; from this point any decrypt worker can call `napi_schedule` and schedule a real poll

#### How `napi_schedule` prevents double-scheduling — `napi_schedule_prep`

**File:** `net/core/dev.c:6729`

```c
bool napi_schedule_prep(struct napi_struct *n)
{
    unsigned long new, val = READ_ONCE(n->state);
    do {
        if (unlikely(val & NAPIF_STATE_DISABLE))
            return false;                               // disabled → no-op
        new = val | NAPIF_STATE_SCHED;
        // if SCHED was already set, also set MISSED:
        new |= (val & NAPIF_STATE_SCHED) / NAPIF_STATE_SCHED * NAPIF_STATE_MISSED;
    } while (!try_cmpxchg(&n->state, &val, new));

    return !(val & NAPIF_STATE_SCHED);  // true only if SCHED was NOT already set
}
```

This is an atomic compare-exchange loop. The outcome:
- If `NAPI_STATE_SCHED` was **not** set → set it atomically, return true → caller proceeds to `__napi_schedule` → NAPI added to CPU's poll_list
- If `NAPI_STATE_SCHED` was **already** set → set `NAPI_STATE_MISSED` atomically, return false → no-op

`NAPI_STATE_MISSED` means: "another `napi_schedule` arrived while the NAPI was already scheduled." When the current poll completes and `napi_complete_done` runs, it checks `NAPI_STATE_MISSED` — if set, it immediately re-schedules the NAPI for another poll. This ensures no wakeup is lost even when `napi_schedule` is called concurrently from multiple CPUs.

**For the EoI:** once a decrypt worker calls `napi_schedule` and SCHED is set, all subsequent `napi_schedule` calls from any CPU (for the same peer) are no-ops. The NAPI remains bound to the CPU that first called `napi_schedule` until `napi_complete_done` clears SCHED. Under high load, multiple decrypt workers calling `napi_schedule` for the same peer will all see SCHED already set and return false — only one GRO fire happens, but it may be on a different CPU from where most decryption is happening.

#### Why per-peer, not per-device?

WireGuard could have used a single shared NAPI for all peers. It uses per-peer instead for two reasons:

1. **Ordering isolation:** each peer's packet stream must be delivered in order independently. A shared NAPI would need per-peer ordering logic anyway. Per-peer NAPI makes each peer's ordered queue the natural unit of GRO work.

2. **Parallelism:** with per-peer NAPI, different peers' GRO polls can run on different CPUs simultaneously. With a single shared NAPI, all peers would serialize through one poll function.

The cost: with 1,000 peers, there are 1,000 `napi_struct` instances, each capable of independently binding to and saturating a CPU's softnet poll list.

#### Teardown sequence — `peer_remove_after_dead` (peer.c:94)

When a peer is removed, the NAPI must be shut down before the `wg_peer` struct is freed:

```c
// peer.c:116
flush_workqueue(peer->device->packet_crypt_wq);   // wait for all encrypt/decrypt workers
// peer.c:118
flush_workqueue(peer->device->packet_crypt_wq);   // second flush — see note below
// peer.c:120
napi_disable(&peer->napi);    // sets NAPI_STATE_DISABLE; waits for any in-flight poll to finish
// peer.c:124
netif_napi_del(&peer->napi);  // removes from device list, clears NAPI_STATE_LISTED
// peer.c:129
flush_workqueue(peer->device->handshake_send_wq); // wait for handshake send worker
```

**Why `flush_workqueue` is called twice:**
The comment at peer.c:108–118 explains: each packet reference has exactly two workqueue lifetimes — once through the encrypt/decrypt stage (`packet_crypt_wq`), and once through the serial ingestion stage (also `packet_crypt_wq` for the TX worker). One flush drains the first stage; a second flush is needed because items queued by the first stage into the second stage (e.g., the TX worker being woken by the encrypt worker) may not yet have run. Two flushes guarantee both generations are drained.

**`napi_disable`:** sets `NAPI_STATE_DISABLE` so that `napi_schedule_prep` returns false immediately — no new polls can be scheduled. Then it busy-waits until any currently-running poll function (`wg_packet_rx_poll`) finishes. After `napi_disable` returns, it is safe to free `peer->rx_queue` and the `napi_struct` itself.

**`netif_napi_del`:** removes the NAPI from the device's NAPI list and clears `NAPI_STATE_LISTED`, making the registration reversible. After this, the memory for `peer->napi` can be freed along with the rest of the `wg_peer` struct.

---

## Part 2 — Key findings for the May 19 meeting

### 2.2 The EoI mechanism is confirmed at source level

The complete EoI chain is traceable:
1. `wg_packet_decrypt_worker` runs in `packet_crypt_wq` (SCHED_NORMAL)
2. After decrypting each packet, calls `wg_queue_enqueue_per_peer_rx` → `napi_schedule(&peer->napi)` at `queueing.h:196`
3. `napi_schedule` records the **current CPU** (stale pointer, not live)
4. When BH is re-enabled (at the next spinlock release in `ptr_ring_consume_bh`), pending GRO softirq fires immediately
5. GRO runs at high priority, finds nothing ready, aborts
6. Pinned core saturates; workers migrate; GRO still targets the old recorded core



| Tracepoint | What it measures | Confirmed applicable |
|---|---|---|
| `workqueue_queue_work` | Moment work is enqueued to `packet_crypt_wq` | Yes — fires when `wg_queue_enqueue_per_device_and_peer` submits to `packet_crypt_wq` |
| `workqueue_execute_start` | Moment worker begins executing | Yes — fires at start of `wg_packet_decrypt_worker` |
| `napi_poll` | NAPI/GRO execution | Yes — fires when `wg_packet_rx_poll` runs |

Interval between `workqueue_queue_work` and `workqueue_execute_start` = scheduler latency for the decryption worker. This is directly measurable on the test environment without any proxy.

---

---

---


*Added May 18, 2026. New objective from Alain: identify which work items call blocking functions.*

## Part 3 — WireGuard work item blocking analysis

### 3.1 All WireGuard work items

| Work item function | Workqueue | Flags | File:Line |
|---|---|---|---|
| `wg_packet_decrypt_worker` | `packet_crypt_wq` | `WQ_CPU_INTENSIVE\|WQ_MEM_RECLAIM\|WQ_PERCPU` | `receive.c:493` |
| `wg_packet_encrypt_worker` | `packet_crypt_wq` | same | `send.c:287` |
| `wg_packet_handshake_receive_worker` | `handshake_receive_wq` | `WQ_CPU_INTENSIVE\|WQ_FREEZABLE\|WQ_PERCPU` | `receive.c:206` |
| `wg_packet_handshake_send_worker` | `handshake_send_wq` | `WQ_UNBOUND\|WQ_FREEZABLE` | `send.c:46` |
| `wg_packet_tx_worker` | `packet_crypt_wq` | `WQ_CPU_INTENSIVE\|WQ_MEM_RECLAIM\|WQ_PERCPU` | `send.c:262` |

How workers are registered: `wg_packet_percpu_multicore_worker_alloc()` in `queueing.c:9` calls `INIT_WORK` for each CPU, binding the worker function to a `multicore_worker` struct. On each enqueue, `queue_work_on(cpu, wq, work)` submits to the specific per-CPU worker.

### 3.2 `wg_packet_decrypt_worker`

**File:** `receive.c:493–507` — **Workqueue:** `packet_crypt_wq` (`WQ_CPU_INTENSIVE | WQ_MEM_RECLAIM | WQ_PERCPU`)

#### Goal and idea

This is the **receive data path, Stage 2**. Its job is to decrypt incoming WireGuard tunnel packets as fast as possible, in parallel across all CPUs.

When a remote peer sends data through the WireGuard tunnel, those packets arrive on the wire as encrypted UDP datagrams. Stage 1 (the UDP receive handler, running in softirq context) strips the outer UDP/IP headers, looks up the keypair by the packet's key index, and pushes the raw encrypted payload into the global per-device decrypt ring. This worker — Stage 2 — is what actually performs the cryptographic work.

One worker is pinned per CPU (`WQ_PERCPU`). All of them consume from the same shared ring simultaneously, so decryption of many packets scales with the number of cores. Each worker independently decrypts its packet and then places it into the per-peer ordered receive queue, so that Stage 3 (NAPI/GRO) can pick them up in order and inject them into the kernel network stack.

**What it accomplishes:** transforms an encrypted network packet into a plaintext inner IP packet, validating its authenticity via ChaCha20-Poly1305 AEAD (if the auth tag doesn't match, the packet is marked DEAD and dropped).

```c
while ((skb = ptr_ring_consume_bh(&queue->ring)) != NULL) {
    state = decrypt_packet(skb, ...) ? PACKET_STATE_CRYPTED : PACKET_STATE_DEAD;
    wg_queue_enqueue_per_peer_rx(skb, state);
}
```

#### Blocking analysis

```
ptr_ring_consume_bh()                         spin_lock_bh / spin_unlock_bh — cannot sleep
  └─ decrypt_packet()                         receive.c:501
       └─ skb_cow_data()                      GFP_ATOMIC allocation — may fail, does not sleep
       └─ chacha20poly1305_decrypt_sg_inplace() pure CPU crypto — no locks, no sleep
       └─ spin_lock_bh (replay counter)       cannot sleep
  └─ wg_queue_enqueue_per_peer_rx()
       └─ atomic_set_release()                atomic store — no sleep
       └─ napi_schedule()                     raises softirq flag — no sleep
```

No `down_read`, `down_write`, `mutex_lock`, `wait_event`, or `schedule()` anywhere.

**Conclusion: non-blocking.** Pure CPU computation. `WQ_CPU_INTENSIVE` is appropriate — this worker deliberately hogs the CPU for crypto and should not be throttled by the concurrency manager.

---

### 3.3 `wg_packet_encrypt_worker`

**File:** `send.c:287–309` — **Workqueue:** `packet_crypt_wq` (`WQ_CPU_INTENSIVE | WQ_MEM_RECLAIM | WQ_PERCPU`)

#### Goal and idea

This is the **send data path, Stage 2** — the symmetric mirror of `wg_packet_decrypt_worker`, but for outgoing packets.

When the local machine sends data through the WireGuard interface, the kernel's networking stack produces a plaintext inner IP packet. Stage 1 (the `dev_start_xmit` path, called when a packet is sent on the WireGuard network interface) looks up the current session keypair for the destination peer, assigns a nonce (monotonically increasing counter), and pushes the packet into the global per-device encrypt ring. This worker encrypts it.

One subtle difference from the decrypt worker: a single "batch" pulled from the ring (`first`) may be a **linked list of skbs** — multiple packets for the same peer, chained together and submitted as one unit. The worker iterates over all of them with `skb_list_walk_safe`, encrypting each in sequence. If any packet in the chain fails encryption, the whole chain is marked DEAD.

After encryption, the batch is handed to `wg_queue_enqueue_per_peer_tx`, which places it into the per-peer TX queue and wakes the TX worker to send it.

**What it accomplishes:** transforms a plaintext inner IP packet into a WireGuard data message — adding the protocol header, padding (to obscure packet lengths), and a 16-byte Poly1305 authentication tag — ready to be sent as a UDP datagram to the peer's endpoint.

```c
while ((first = ptr_ring_consume_bh(&queue->ring)) != NULL) {
    enum packet_state state = PACKET_STATE_CRYPTED;
    skb_list_walk_safe(first, skb, next) {
        if (likely(encrypt_packet(skb, PACKET_CB(first)->keypair)))
            wg_reset_packet(skb, true);
        else { state = PACKET_STATE_DEAD; break; }
    }
    wg_queue_enqueue_per_peer_tx(first, state);
}
```

#### Blocking analysis

Identical structure to the decrypt worker. `encrypt_packet` is pure ChaCha20-Poly1305 AEAD with no sleeping primitives. `wg_queue_enqueue_per_peer_tx` is an atomic store plus `queue_work_on`.

**Conclusion: non-blocking.** Same reasoning as decrypt.

---

### 3.4 `wg_packet_tx_worker`

**File:** `send.c:262–285` — **Workqueue:** `packet_crypt_wq` (`WQ_CPU_INTENSIVE | WQ_MEM_RECLAIM | WQ_PERCPU`)

Confirmed at `queueing.h:183–184`:
```c
queue_work_on(wg_cpumask_choose_online(&peer->serial_work_cpu, peer->internal_id),
              peer->device->packet_crypt_wq, &peer->transmit_packet_work);
```

#### Goal and idea

This is the **send data path, Stage 3** — the per-peer TX serializer.

The problem it solves: after encryption, multiple packets for the same peer may have been processed by different CPU workers in parallel, finishing in arbitrary order. If we sent them the moment each worker finished, packets would arrive at the remote peer out of order, which confuses TCP. The TX worker enforces in-order delivery before transmission.

Each peer has its own per-peer TX queue (`peer->tx_queue`). Encrypt workers place packets into this queue in their original send order, initially with state UNCRYPTED. When an encrypt worker finishes a packet, it sets the state to CRYPTED atomically. The TX worker then walks this queue from the head — exactly like the RX poll does on the receive side — processing CRYPTED packets in order and stopping at the first UNCRYPTED one. This guarantees that even if packet N+1 was encrypted before packet N, packet N is always sent first.

There is exactly **one TX worker per peer** (dispatched via `peer->transmit_packet_work`). This single-consumer design avoids the need for any per-peer locking on the TX side — only one goroutine ever reads from the head of the per-peer TX queue at a time.

**What it accomplishes:** picks up encrypted packets from the per-peer TX queue in the correct order and calls `wg_socket_send_skb_to_peer` to transmit each one as a UDP datagram to the peer's last-known endpoint address.

```c
while ((first = wg_prev_queue_peek(&peer->tx_queue)) != NULL &&
       (state = atomic_read_acquire(&PACKET_CB(first)->state)) != PACKET_STATE_UNCRYPTED) {
    wg_prev_queue_drop_peeked(&peer->tx_queue);
    if (likely(state == PACKET_STATE_CRYPTED))
        wg_packet_create_data_done(peer, first);  // → wg_socket_send_skb_to_peer
    else
        kfree_skb_list(first);
}
```

#### Blocking analysis

```
wg_prev_queue_peek()              reads prev_queue — no sleep
atomic_read_acquire()             atomic read — no sleep
wg_packet_create_data_done()      send.c:242
  └─ wg_timers_*()                spinlock-based timer updates — no sleep
  └─ wg_socket_send_skb_to_peer() UDP send — non-blocking in normal path
  └─ keep_key_fresh()             checks if rekeying needed — no sleep
wg_noise_keypair_put()            reference count decrement — no sleep
wg_peer_put()                     reference count decrement — no sleep
cond_resched()                    voluntary yield — not a sleep
```

`wg_socket_send_skb_to_peer` calls into the UDP send path. UDP sends in kernel space can transiently acquire socket locks, but WireGuard's socket is pre-configured and sends are non-blocking — no `wait_event`, no `down_write`, no sleeping lock in the normal path.

**Conclusion: non-blocking.** `WQ_CPU_INTENSIVE` appropriate.

---

### 3.5 `wg_packet_handshake_receive_worker` — **BLOCKING CONFIRMED**

**File:** `receive.c:206–218` — **Workqueue:** `handshake_receive_wq` (`WQ_CPU_INTENSIVE | WQ_FREEZABLE | WQ_PERCPU`)

#### Goal and idea

This is the **control path, receive side**. It handles incoming WireGuard handshake messages — not data packets, but the session establishment messages of the Noise Protocol.

Before any data can flow between two WireGuard peers, they must complete a Noise Protocol handshake: the initiator sends a handshake initiation, the responder replies with a handshake response, and both sides derive a shared symmetric session keypair from the exchange. WireGuard also rekeyes automatically every 3 minutes (`REKEY_AFTER_TIME`) or after 2^60 packets, so this worker runs throughout the lifetime of the tunnel — not just at startup.

Handshake packets arrive on the same UDP socket as data packets. The UDP receive handler distinguishes them by the message type field and pushes them into a separate `handshake_queue`. This worker drains that queue by calling `wg_receive_handshake_packet`, which does the following:

1. **Cookie handling:** if the packet is a cookie reply (type `MESSAGE_HANDSHAKE_COOKIE`), pass it to the cookie consumer and return — no crypto needed.
2. **DDoS load detection:** if the handshake queue is more than 1/8 full, the system considers itself under load. Under load, it requires the second "cookie" MAC before processing the handshake — this makes spoofed flood attacks more expensive for attackers.
3. **MAC validation:** two MACs per handshake packet are verified. Invalid MACs are dropped immediately, before any expensive crypto.
4. **Noise cryptography (`noise.c`):** the actual Diffie-Hellman and key derivation:
   - For a **handshake initiation**: decrypt the initiator's ephemeral public key, verify the initiator's static identity, derive intermediate keys, store the partial handshake state, prepare and send the response.
   - For a **handshake response**: complete the key derivation using the responder's ephemeral key, call `wg_noise_handshake_begin_session` to derive the final symmetric session keypair.

**What it accomplishes:** on a complete two-message exchange, a new `noise_keypair` (holding the symmetric ChaCha20-Poly1305 keys) is installed into the peer's keypair set. From that point on, data packets can be encrypted and decrypted using that session key.

```c
while ((skb = ptr_ring_consume_bh(&queue->ring)) != NULL) {
    wg_receive_handshake_packet(wg, skb);  // full Noise protocol processing
    dev_kfree_skb(skb);
    atomic_dec(&wg->handshake_queue_len);
}
```

#### Blocking analysis

```
ptr_ring_consume_bh()                              spinlock — no sleep
  └─ wg_receive_handshake_packet()                 receive.c:92
       └─ wg_cookie_validate_packet()              MAC validation — spinlock only
       └─ wg_noise_handshake_consume_initiation()  noise.c:~520
            └─ wait_for_random_bytes()             noise.c:527  ← SLEEPS until CRNG ready
            └─ down_read(&static_identity->lock)   noise.c:529  ← SLEEPS if write-locked
            └─ down_write(&handshake->lock)        noise.c:530  ← SLEEPS if held by anyone
       └─ wg_noise_handshake_consume_response()    noise.c:~670
            └─ down_read(&static_identity->lock)   noise.c:678  ← SLEEPS if write-locked
            └─ down_write(&handshake->lock)        noise.c:679  ← SLEEPS if held
       └─ wg_noise_handshake_begin_session()       noise.c:816
            └─ down_write(&handshake->lock)        noise.c:822  ← SLEEPS if held
```

**`down_read` / `down_write`** are rwsemaphore operations — sleeping locks. `down_write` puts the calling thread to sleep if any reader or writer holds the lock. `down_read` sleeps only if a writer holds it. Since `handshake->lock` serializes all handshake operations for a given peer, concurrent handshake packets for the same peer will contend on this lock and block.

**`wait_for_random_bytes()` (noise.c:527):** blocks until the kernel CSPRNG is fully seeded. Relevant at early boot — after boot, this is effectively a no-op since the CRNG is already ready.

**Conclusion: BLOCKING.** Every handshake processing call acquires sleeping locks. Under high connection churn, workers block on lock contention. With `WQ_PERCPU`, a blocked worker on CPU N stalls all handshake processing for packets arriving on CPU N.

---

### 3.6 `wg_packet_handshake_send_worker` — **BLOCKING CONFIRMED**

**File:** `send.c:46–53` — **Workqueue:** `handshake_send_wq` (`WQ_UNBOUND | WQ_FREEZABLE`)

#### Goal and idea

This is the **control path, send side**. It initiates a WireGuard Noise handshake toward a remote peer.

This worker is triggered in three situations:
- **Session establishment:** when there is no valid current session keypair for a peer and data needs to be sent. The data packets are held in `staged_packet_queue` until a session is established.
- **Proactive rekeying:** `keep_key_fresh` (called at the end of `wg_packet_create_data_done`, i.e., after every data send) checks whether the current session is approaching its expiry. If so, it queues this worker to initiate a new handshake while the old key is still valid, avoiding any disruption to data flow.
- **Retry after timeout:** if the remote peer does not respond to a handshake initiation within `REKEY_TIMEOUT` (5 seconds), the timer system re-queues this worker. Up to `MAX_TIMER_HANDSHAKES` (90 / 5 = 18) retries before giving up.

The work itself implements the Noise Protocol initiator role: generate a fresh ephemeral Diffie-Hellman keypair, compute the handshake message (mixing in the initiator's static identity, the peer's static public key, and the ephemeral key), encrypt the initiator's identity, build the `message_handshake_initiation` struct, add both MACs, and send it over UDP to the peer's last known endpoint.

Unlike the receive worker (which processes a queue of many packets), this worker handles exactly **one peer per dispatch**. It is stored in `peer->transmit_handshake_work` and uses `wg_peer_get` to hold a reference to the peer until the worker completes (`wg_peer_put` at the end).

**What it accomplishes:** sends a Noise handshake initiation message to a peer, starting or continuing the session establishment process. Without this worker, no data can ever be sent to a peer — all data path workers depend on a valid session keypair being present.

```c
void wg_packet_handshake_send_worker(struct work_struct *work)
{
    struct wg_peer *peer = container_of(work, struct wg_peer, transmit_handshake_work);
    wg_packet_send_handshake_initiation(peer);   // full Noise initiator crypto
    wg_peer_put(peer);                           // release the reference taken at queue time
}
```

#### Blocking analysis

`wg_packet_send_handshake_initiation` → `wg_noise_handshake_create_initiation` (`noise.c:~520`):

```
wait_for_random_bytes()              noise.c:527  ← SLEEPS until CRNG ready
down_read(&static_identity->lock)    noise.c:529  ← SLEEPS if write-locked
down_write(&handshake->lock)         noise.c:530  ← SLEEPS if held by anyone
```

Same blocking primitives as the receive worker. `handshake->lock` serializes all handshake operations for a given peer — only one CPU can hold it for writing at a time, so simultaneous send and receive handshake processing for the same peer will contend.

**Key difference from receive worker:** `handshake_send_wq` is `WQ_UNBOUND`. Workers are not pinned to a specific CPU — the unbound pool can wake a worker on any available CPU. A blocked send worker does not permanently occupy a per-CPU slot, making it more resilient to lock contention than the receive worker.

**Conclusion: BLOCKING.** Same sleeping locks as the receive worker, but lower structural impact due to `WQ_UNBOUND`.

### 3.7 Summary: blocking behavior by work item

| Work item | Blocking calls | Impact |
|---|---|---|
| `wg_packet_decrypt_worker` | None | Pure CPU; `WQ_CPU_INTENSIVE` appropriate |
| `wg_packet_encrypt_worker` | None | Pure CPU; `WQ_CPU_INTENSIVE` appropriate |
| `wg_packet_tx_worker` | None | Per-peer TX serializer; UDP send non-blocking in normal path |
| `wg_packet_handshake_receive_worker` | `down_read/write` (rwsem), `wait_for_random_bytes` | **Sleeping locks** — thread blocks on lock contention; CRNG wait on startup |
| `wg_packet_handshake_send_worker` | `down_read/write` (rwsem), `wait_for_random_bytes` | Same — `WQ_UNBOUND` so no CPU pinning, but still blocks |

### 3.7 Interpretation: does this explain the performance problem?

The blocking in handshake workers is real but likely **not the primary cause** of the 19.2% throughput ceiling in the paper's scenario (1,000 clients, sustained data transfer). Handshakes happen only at session establishment, not on every data packet. During a sustained benchmark, handshake rate is low compared to data packet rate.

The primary bottleneck in the paper's scenario is EoI in `wg_packet_decrypt_worker` — not blocking, but priority inversion via `napi_schedule`. The data worker itself is non-blocking.

However, the blocking in handshake workers becomes significant under:
- High connection churn (many clients reconnecting frequently)
- Rekeying pressure (sessions expiring every ~3 minutes with ~1000 clients = ~5 rekeying events/second)
- Early boot (CRNG not seeded — `wait_for_random_bytes` stalls all handshakes)

**This is the new research angle Alain wants explored**: characterize how often the handshake workers block, under what conditions, and whether that blocking is an independent contributor to observed latency.

---

## Part 4 — kernel/workqueue.c: concurrency management and blocking behavior

*Added May 19, 2026. Key question: what happens to a `WQ_CPU_INTENSIVE` pool when a thread blocks?*

### 4.1 The `nr_running` counter and concurrency management

The workqueue subsystem tracks a per-pool counter `nr_running` (defined at `workqueue.c:211`). This counter controls whether new workers need to be woken up:

```c
/* workqueue.c:950–964 */
static bool need_more_worker(struct worker_pool *pool)
{
    return !list_empty(&pool->worklist) && !pool->nr_running;
}

static bool keep_working(struct worker_pool *pool)
{
    return !list_empty(&pool->worklist) && (pool->nr_running <= 1);
}
```

The concurrency management goal: keep exactly one runnable worker per pool per CPU. If a worker sleeps, `nr_running` drops, and `kick_pool` wakes another idle worker to compensate.

### 4.2 `WORKER_CPU_INTENSIVE` removes workers from `nr_running`

The flag `WORKER_CPU_INTENSIVE` is part of the `WORKER_NOT_RUNNING` mask (`workqueue.c:97`):

```c
WORKER_NOT_RUNNING = WORKER_PREP | WORKER_CPU_INTENSIVE | WORKER_UNBOUND | WORKER_REBOUND;
```

When a work item starts running on a `WQ_CPU_INTENSIVE` workqueue, the worker is immediately flagged:

```c
/* workqueue.c:3263–3264 */
if (unlikely(pwq->wq->flags & WQ_CPU_INTENSIVE))
    worker_set_flags(worker, WORKER_CPU_INTENSIVE);
```

`worker_set_flags` with a `WORKER_NOT_RUNNING` flag decrements `pool->nr_running` (`workqueue.c:999`).

**Effect:** The `WQ_CPU_INTENSIVE` worker is excluded from concurrency accounting from the moment it starts executing. The pool's `nr_running` is decremented. If there are pending work items and no other running workers, `kick_pool` will wake an idle worker.

**In plain terms:** setting `WQ_CPU_INTENSIVE` does not prevent a worker from blocking — it just tells the concurrency manager not to count this worker as "running" for throttling purposes. Another idle worker can be woken up immediately to handle pending items.

### 4.3 What happens when a worker sleeps (`wq_worker_sleeping`)

When any worker goes to sleep (enters `schedule()`), the scheduler calls `wq_worker_sleeping`:

```c
/* workqueue.c:1453–1490 */
void wq_worker_sleeping(struct task_struct *task)
{
    /* ... */
    pool->nr_running--;
    if (kick_pool(pool))    // wakes an idle worker if needed
        worker->current_pwq->stats[PWQ_STAT_CM_WAKEUP]++;
}
```

And when it wakes up, `wq_worker_running` is called:

```c
/* workqueue.c:1419–1444 */
void wq_worker_running(struct task_struct *task)
{
    if (!(worker->flags & WORKER_NOT_RUNNING))
        worker->pool->nr_running++;
    /* ... */
}
```

**Critical observation:** For a `WQ_CPU_INTENSIVE` worker, `WORKER_CPU_INTENSIVE` is already set (part of `WORKER_NOT_RUNNING`), so when it sleeps, `wq_worker_sleeping` returns early at line 1463 (`if (worker->flags & WORKER_NOT_RUNNING) return;`). The `nr_running` was already decremented when the work started. **No double decrement.**

Similarly, when the `WQ_CPU_INTENSIVE` worker wakes from a sleeping lock, `wq_worker_running` checks `!(worker->flags & WORKER_NOT_RUNNING)` → condition is false → **no increment**. The worker stays excluded from `nr_running` until the work item completes, at which point `WORKER_CPU_INTENSIVE` is cleared (`workqueue.c:3358`).

### 4.4 `kick_pool`: waking idle workers

```c
/* workqueue.c:1267–1315 */
static bool kick_pool(struct worker_pool *pool)
{
    struct worker *worker = first_idle_worker(pool);
    /* ... */
    if (!need_more_worker(pool) || !worker)
        return false;
    /* ... */
    wake_up_process(p);
    return true;
}
```

`kick_pool` wakes the most-recently-idle worker if `need_more_worker` is true (worklist not empty AND `nr_running == 0`). This is the mechanism that spawns additional workers when existing ones are blocked.

### 4.5 `WQ_MEM_RECLAIM` and the rescuer thread

`WQ_MEM_RECLAIM` (`packet_crypt_wq` has this) guarantees that even under memory pressure, at least one worker will always be available to make progress. It does this by creating a dedicated "rescuer" thread (`workqueue.c:5705–5735`). This is relevant for correctness under memory pressure, not for normal throughput analysis.

### 4.6 `WQ_PERCPU` — what it means for blocked workers

`WQ_PERCPU` (not a standard kernel flag — WireGuard defines its own via `alloc_workqueue`) means workers are pinned to specific CPUs via `queue_work_on(cpu, wq, work)`. When a per-CPU `WQ_CPU_INTENSIVE` worker blocks (e.g., on an rwsem in handshake processing):

1. Worker is already excluded from `nr_running` (set at work start — step 6.2)
2. `wq_worker_sleeping` returns early (step 6.3) — no redundant decrement
3. `kick_pool` was already called when work started (step 6.4) — an idle worker on the same CPU should have been woken
4. But with `WQ_PERCPU`, the replacement worker is bound to the **same CPU**. If there are no idle workers on that CPU, the queue stalls until the sleeping worker wakes.

**This is the key constraint for handshake workers:** `handshake_receive_wq` is `WQ_CPU_INTENSIVE | WQ_PERCPU`. If the per-CPU worker pool has no idle worker ready (e.g., all pre-spawned workers are busy), incoming handshakes on that CPU can queue up while the active worker sleeps on `down_write(&handshake->lock)`.

**`handshake_send_wq` is different:** it's `WQ_UNBOUND | WQ_FREEZABLE`. Unbound workers float across CPUs and are managed by a global unbound pool. When the handshake send worker sleeps, the pool can wake a worker on any CPU — better resilience, but no NUMA/cache locality guarantees.

### 4.7 Auto-detection: dynamic `WQ_CPU_INTENSIVE` promotion

Beyond the static `WQ_CPU_INTENSIVE` flag, the kernel also auto-promotes concurrency-managed workers dynamically via `wq_worker_tick` (`workqueue.c:1499–1538`): if a concurrency-managed worker hogs the CPU for longer than `wq_cpu_intensive_thresh_us` (default: configured at boot via `/sys/module/workqueue/parameters/cpu_intensive_thresh_us`), it is automatically flagged `WORKER_CPU_INTENSIVE` and kicked out of `nr_running`. This prevents long-running work items from blocking shorter ones on the same CPU.

WireGuard's decrypt/encrypt workers use static `WQ_CPU_INTENSIVE`, not the dynamic mechanism — they declare up front that they won't participate in concurrency management.

### 4.8 Summary: implications for WireGuard handshake blocking

| Scenario | What kernel does | Impact |
|---|---|---|
| Handshake receive worker starts | `WORKER_CPU_INTENSIVE` set → `nr_running--` → `kick_pool` wakes idle worker | Another worker can run on same CPU while handshake executes |
| Handshake receive worker hits `down_write` | Thread sleeps; `wq_worker_sleeping` returns early (already NOT_RUNNING) | No additional kick; sleeping worker is simply off-CPU |
| No idle worker available on this CPU | `kick_pool` has no one to wake | Pending handshakes on this CPU queue up; stall until sleeping worker returns |
| Handshake send worker hits `down_write` | Thread sleeps; unbound pool finds any-CPU idle worker | Lower stall risk, but still blocks |
| `wait_for_random_bytes` at boot | All handshake workers on all CPUs block until CRNG ready | Complete handshake stall at boot — no crypto possible |

**Bottom line for Alain:** The handshake workers do call sleeping locks (`down_write`/`down_read`). The `WQ_CPU_INTENSIVE` flag does NOT prevent them from blocking; it only tells the concurrency manager not to count them as "running" so other work items can proceed. Under high rekeying pressure (e.g., ~5 sessions/second with 1,000 clients every 3 minutes), each per-CPU handshake pool has a fixed number of workers. If those workers pile up sleeping on `down_write(&handshake->lock)` (which serializes per-peer handshake state), incoming handshake packets queue up and overall latency grows.

---

## Study log

| Date | Files read | Key finding |
|---|---|---|
| 2026-05-15 | `drivers/net/wireguard/receive.c`, `queueing.h`, `device.c` | EoI chain confirmed at source level; napi_schedule stale pointer at queueing.h:196; packet_crypt_wq is WQ_CPU_INTENSIVE\|WQ_PERCPU not WQ_UNBOUND |
| 2026-05-18 | `receive.c`, `send.c`, `noise.c`, `queueing.c` | **New objective**: work item inventory + blocking analysis. Decrypt/encrypt workers: non-blocking (pure ChaCha20). Handshake workers: blocking — rwsem (down_read/write) and wait_for_random_bytes |
| 2026-05-19 | `kernel/workqueue.c` | `WQ_CPU_INTENSIVE` removes worker from `nr_running` at work start (not at sleep). Sleeping `WQ_CPU_INTENSIVE` workers do NOT trigger extra `kick_pool` (already NOT_RUNNING). Per-CPU pool + blocked worker = queue stall on that CPU if no idle worker available. `handshake_receive_wq` (PERCPU) more vulnerable than `handshake_send_wq` (UNBOUND). |

---

## Still to read

- [x] `kernel/workqueue.c` — `WQ_CPU_INTENSIVE` effect on concurrency limit; what happens to pool when a thread blocks — **Part 6**
- [x] `drivers/net/wireguard/peer.c` — per-peer NAPI setup, `netif_napi_add` call — **Part 1.9**
