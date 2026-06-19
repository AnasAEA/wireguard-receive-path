# WireGuard Pipeline — Sketch Guide
# Visual reference for diagrams and figures

---

## Overview: what to draw

There are five key diagrams. Each one is described below with its components, the relationships between them, example scenarios, and labelling notes.

---

## Diagram 1 — The three-stage receive pipeline (top-level view)

### What this diagram shows

The high-level flow of an incoming encrypted packet through WireGuard's three pipeline stages, from NIC to the kernel network stack.

### Components to draw

**The NIC (left side)**
- Arrow labeled "encrypted UDP datagrams" entering from the left
- Single physical network interface

**Stage 1 — UDP Receive Handler**
- Label: "Stage 1: UDP Handler"
- Context label: "softirq / BH priority"
- Priority badge: HIGH (red or orange)
- What it does: strip outer UDP/IP headers, look up keypair by key index, enqueue to two queues simultaneously
- Outputs two arrows:
  - Arrow 1 → per-peer RX queue (labeled "ordered arrival queue")
  - Arrow 2 → global device ring (labeled "decrypt ring — round robin across CPUs")

**Stage 2 — Decrypt Workers**
- Label: "Stage 2: Decrypt Workers (packet_crypt_wq)"
- Context label: "SCHED_NORMAL / WQ_PERCPU"
- Priority badge: NORMAL (green)
- Draw N boxes, one per CPU (CPU 0, CPU 1, CPU 2, CPU 3...)
- Each worker box:
  - Reads from the global device ring
  - Performs ChaCha20-Poly1305 decryption
  - Writes state to per-peer RX queue (CRYPTED or DEAD)
  - Calls napi_schedule (→ Stage 3)
- Label the arrow from ring to workers: "ptr_ring_consume_bh (round-robin)"

**Stage 3 — GRO Poll**
- Label: "Stage 3: wg_packet_rx_poll (NAPI)"
- Context label: "softirq / BH priority"
- Priority badge: HIGH (red or orange)
- One box per peer (each peer has its own NAPI instance)
- What it does: walk per-peer RX queue from head, deliver CRYPTED packets to kernel stack
- Output arrow → "Linux network stack (TCP/IP)"

**Key annotations**
- Stage 1 and Stage 3 are both at BH priority → draw them at the same vertical level (top)
- Stage 2 is at SCHED_NORMAL → draw it at a lower vertical level
- The upward arrow from Stage 2 → Stage 3 is labeled "napi_schedule raises NET_RX_SOFTIRQ"

---

## Diagram 2 — The two parallel queues (data structure view)

### What this diagram shows

How a single incoming packet is simultaneously inserted into two completely different queues, and why these queues serve different purposes.

### The scenario: 4 packets arriving from Peer A

**Global device ring (ptr_ring)** — shared across ALL peers, all CPUs
- Draw as a horizontal circular buffer
- Packets from all peers mixed together: [PeerA-pkt0] [PeerB-pkt5] [PeerA-pkt1] [PeerC-pkt2] [PeerA-pkt2] ...
- Label: "One ring for the entire WireGuard device"
- Label: "Consumed by workers in round-robin CPU order"
- Arrow at the tail labeled "ptr_ring_produce_bh (Stage 1)"
- Arrow at the head labeled "ptr_ring_consume_bh (Worker on CPU N)"

**Per-peer RX queue (prev_queue)** — one per peer, insertion order = arrival order
- Draw as a vertical linked list for Peer A only
- Entries in strict arrival order:
  ```
  [pkt 0: UNCRYPTED] ← tail (oldest, consumed first)
  [pkt 1: UNCRYPTED]
  [pkt 2: UNCRYPTED]
  [pkt 3: UNCRYPTED] ← head (newest)
  ```
- Label: "One queue per peer — order fixed at insertion"
- Label: "State flips atomically: UNCRYPTED → CRYPTED or DEAD"
- Label at the tail: "wg_prev_queue_dequeue (consumer: wg_packet_rx_poll)"
- Label at the head: "wg_prev_queue_enqueue (producer: Stage 1)"

**The two-phase enqueue (show with arrows)**
- Stage 1 processes packet, looks up peer
- Arrow 1 (labeled "Phase 1 — first"): packet → per-peer RX queue. State set to UNCRYPTED.
- Arrow 2 (labeled "Phase 2 — then"): packet → global device ring. Worker dispatched on CPU N.
- Caption: "Ordering is established in Phase 1. Decryption assignment happens in Phase 2."

**Key annotation**
- Draw a box showing: "The per-peer queue fixes WHAT ORDER packets are delivered. The device ring determines WHICH CPU decrypts each packet. These are independent."

---

## Diagram 3 — Concurrent decryption and the ordering constraint

### What this diagram shows

How 4 packets from the same peer are decrypted in parallel on 4 CPUs, and why GRO cannot deliver them out of order.

### The setup

- 4 packets arrive from Peer A in order: pkt 0, pkt 1, pkt 2, pkt 3
- Stage 1 enqueues them to per-peer RX queue (in order) and to the device ring (round-robin)
- CPU assignment (round-robin): CPU 0 → pkt 0, CPU 1 → pkt 1, CPU 2 → pkt 2, CPU 3 → pkt 3

**Draw a timeline (horizontal = time, vertical = 4 CPUs)**

```
Time →

CPU 0:  [busy with other peer's packet]...[starts pkt 0]........[marks pkt 0 CRYPTED] → napi_schedule
CPU 1:  [idle]....................[starts pkt 1]...[marks pkt 1 CRYPTED] → napi_schedule (no-op, SCHED set)
CPU 2:  [idle]............[starts pkt 2][marks pkt 2 CRYPTED] → napi_schedule (no-op, SCHED set)
CPU 3:  [idle].....[starts pkt 3].....[marks pkt 3 CRYPTED] → napi_schedule → GRO FIRES HERE
                                                               ↑ GRO fires on CPU 3
                                                               finds head (pkt 0) UNCRYPTED
                                                               exits with work_done = 0
```

**Draw the per-peer RX queue state at the moment GRO fires (after CPU 3 finishes)**

```
[pkt 0: UNCRYPTED] ← head (tail of linked list) — CPU 0 still working
[pkt 1: CRYPTED]   ← done
[pkt 2: CRYPTED]   ← done
[pkt 3: CRYPTED]   ← just done, triggered GRO
```

**GRO poll flow (draw as flowchart)**
- "Peek at tail (pkt 0)"
- Decision diamond: "state == UNCRYPTED?"
- YES → "exit immediately, work_done = 0"
- NO → "deliver packet, advance, peek next, repeat"

**Key annotation**
- "GRO cannot skip pkt 0 to deliver pkt 1. TCP requires in-order delivery."
- "CPU 3 finishing first is the common case — probability that CPU 0 finishes first is 1/N"
- "CPU 0 started last: it was busy with another peer's packet when pkt 0 arrived"

---

## Diagram 4 — The EoI cycle in detail (the bug)

### What this diagram shows

The exact sequence of events that creates the wasted GRO cycle on one CPU, at per-instruction granularity.

### Setup

Focus on a single CPU (CPU 0) running the decrypt worker. It is processing packets from its per-CPU queue in a tight loop.

**Draw the loop as a vertical sequence of steps with timing markers**

**Iteration N (pkt N being processed):**
```
Step 1: ptr_ring_consume_bh()
        ├─ spin_lock_bh()          → BH DISABLED (softirqs cannot fire)
        ├─ __ptr_ring_consume()    → pull pkt N from ring
        └─ spin_unlock_bh()        → BH ENABLED → local_bh_enable()
                                     ↳ if NET_RX_SOFTIRQ pending: fires HERE
                                        (but not yet, no pending softirq at start of N)

Step 2: decrypt_packet(pkt N)      → ChaCha20-Poly1305, pure CPU, ~few microseconds

Step 3: wg_queue_enqueue_per_peer_rx(pkt N, CRYPTED)
        ├─ atomic_set_release(CRYPTED)   → pkt N marked ready
        └─ napi_schedule(&peer->napi)    → NET_RX_SOFTIRQ RAISED ← softirq now pending
                                           (does NOT fire yet — BH currently enabled,
                                            but napi_schedule uses irq_save/restore, not bh_enable)
```

**Iteration N+1 (pkt N+1 being processed):**
```
Step 1: ptr_ring_consume_bh()
        ├─ spin_lock_bh()          → BH DISABLED
        ├─ __ptr_ring_consume()    → pull pkt N+1 from ring
        └─ spin_unlock_bh()
             └─ local_bh_enable()
                  └─ do_softirq()
                       └─ NET_RX_SOFTIRQ ← GRO FIRES HERE ←
                            └─ wg_packet_rx_poll()
                                 ├─ peek at queue head
                                 ├─ head is UNCRYPTED (other CPU still decrypting)
                                 └─ return 0, napi_complete_done clears SCHED
                  (worker resumes here, pkt N+1 in hand)

Step 2: decrypt_packet(pkt N+1)    → crypto again

Step 3: wg_queue_enqueue_per_peer_rx(pkt N+1, CRYPTED)
        └─ napi_schedule()         → NET_RX_SOFTIRQ raised AGAIN
```

**Key annotations**
- Draw a red arrow from Step 3 of iteration N to Step 1 of iteration N+1 labeled "softirq fires between packets, not after"
- Draw a yellow box around the GRO execution labeled "WASTED: work_done = 0"
- Add a counter: "This happens once per decrypted packet. At 25 Gbps: millions of times per second."

**The self-reinforcing loop (draw as a cycle)**
- "Worker decrypts pkt" → "calls napi_schedule" → "GRO fires (preempts at next spin_unlock_bh)" → "GRO finds UNCRYPTED head" → "GRO exits (work_done=0)" → "Worker resumes" → back to start
- Label the cycle: "This runs for every packet in the ring. CPU at 94% utilization."

---

## Diagram 5 — The fix: conditional napi_schedule

### What this diagram shows

How the same scenario plays out with the conditional check added to `wg_queue_enqueue_per_peer_rx`.

### The new Step 3 (modified)

```
Step 3 (PATCHED): wg_queue_enqueue_per_peer_rx(pkt N, CRYPTED)
        ├─ atomic_set_release(CRYPTED)     → pkt N marked ready
        ├─ tail = READ_ONCE(peer->rx_queue.tail)   → read head atomically (hint only)
        ├─ Decision:
        │    ├─ tail == STUB sentinel?     → schedule (conservative)
        │    ├─ tail->state == UNCRYPTED?  → SKIP napi_schedule ← new behavior
        │    └─ tail->state != UNCRYPTED?  → schedule normally
        └─ (if skipped: NET_RX_SOFTIRQ never raised, no GRO invocation)
```

### Scenario A — Head is UNCRYPTED (CPU 3 finishes pkt 3 first, CPU 0 still on pkt 0)

```
Per-peer RX queue at time of check:
[pkt 0: UNCRYPTED] ← tail (CPU 0 still decrypting)
[pkt 1: CRYPTED]
[pkt 2: CRYPTED]
[pkt 3: CRYPTED]   ← CPU 3 just finished, runs Step 3

CPU 3 reads tail → state == UNCRYPTED → SKIP napi_schedule
NET_RX_SOFTIRQ is NOT raised.
No GRO invocation. No preemption.
CPU 3 moves to next packet.
```

Draw: green checkmark on CPU 3's decision. Label: "0 wasted GRO calls."

### Scenario B — Head becomes CRYPTED (CPU 0 finishes pkt 0)

```
Per-peer RX queue at time of check:
[pkt 0: CRYPTED]   ← tail — CPU 0 just finished, state = CRYPTED
[pkt 1: CRYPTED]
[pkt 2: CRYPTED]
[pkt 3: CRYPTED]

CPU 0 reads tail → state == CRYPTED → call napi_schedule
GRO fires → walks queue → delivers pkts 0, 1, 2, 3 in order
work_done = 4. Useful work done.
```

Draw: green checkmark. Label: "GRO fires exactly when it can make progress."

### The residual gap scenario (limitation)

```
Queue after GRO delivers pkts 0 and 1:
[pkt 2: UNCRYPTED] ← new tail (CPU 2 still decrypting)
[pkt 3: CRYPTED]

GRO stops here: work_done = 2, napi_complete_done clears NAPI_STATE_SCHED.

CPU 3 already finished pkt 3. Checks tail → UNCRYPTED → skips napi_schedule. CORRECT.
CPU 2 finishes pkt 2. Checks tail → CRYPTED → calls napi_schedule. CORRECT.
  BUT: if CPU 2 calls napi_schedule in the tiny window before napi_complete_done clears SCHED:
    → napi_schedule is a no-op (SCHED still set)
    → GRO then clears SCHED
    → nobody reschedules
    → pkts 2 and 3 wait until next packet arrives
```

Draw: orange warning box labeled "Residual latency spike — rare, not a correctness issue."

### Side-by-side comparison (summary table for diagram)

```
                    BEFORE FIX          AFTER FIX
napi_schedule calls: every packet       only when head is non-UNCRYPTED
GRO invocations:     millions/sec       proportional to actual deliverable runs
Wasted GRO polls:    ~87.5% (8 cores)  ~0% (primary storm eliminated)
CPU utilization:     94% (mostly waste) reduced — decrypt workers run more freely
Residual gap risk:   N/A               narrow window, sub-microsecond, rare
```

---

## Diagram 6 — NAPI per-peer architecture (supporting diagram)

### What this diagram shows

Why WireGuard uses one napi_struct per peer instead of one shared NAPI for the whole device, and what this means for the EoI.

### Per-peer NAPI instances

Draw 4 peer boxes side by side:

```
Peer A                  Peer B                  Peer C                  Peer D
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│ napi_struct A   │    │ napi_struct B   │    │ napi_struct C   │    │ napi_struct D   │
│ poll: rx_poll   │    │ poll: rx_poll   │    │ poll: rx_poll   │    │ poll: rx_poll   │
│ state: SCHED?   │    │ state: SCHED?   │    │ state: SCHED?   │    │ state: SCHED?   │
│ rx_queue: [...] │    │ rx_queue: [...] │    │ rx_queue: [...] │    │ rx_queue: [...] │
└─────────────────┘    └─────────────────┘    └─────────────────┘    └─────────────────┘
        ↓                      ↓                      ↓                      ↓
  bound to CPU 0         bound to CPU 1         bound to CPU 0         bound to CPU 3
  (napi_schedule         (napi_schedule         (napi_schedule         (napi_schedule
   captured CPU 0)        captured CPU 1)        captured CPU 0)        captured CPU 3)
```

- Annotation: "With 1,000 peers: 1,000 independent napi_struct instances"
- Annotation: "Each can independently bind to any CPU and trigger a GRO poll"
- Annotation: "Two peers can be bound to the same CPU — they share a softnet poll_list"

### napi_schedule CPU binding (important mechanism)

Draw a single CPU's softnet_data structure:

```
CPU 0 — softnet_data
┌──────────────────────────────┐
│ poll_list:                   │
│   → napi_struct (Peer A)     │  ← added by napi_schedule from CPU 0
│   → napi_struct (Peer C)     │  ← added by napi_schedule from CPU 0
│                              │
│ NET_RX_SOFTIRQ flag: SET     │
└──────────────────────────────┘
```

- Arrow from "Worker on CPU 0 calls napi_schedule(&peer_A->napi)" → "this_cpu_ptr(&softnet_data)" → "list_add_tail to CPU 0's poll_list"
- Annotation: "this_cpu_ptr captures the CPU at the moment napi_schedule is called — NOT the best CPU, NOT where GRO is needed, just wherever the worker happened to be running"

### napi_enable / napi_disable lifecycle

Draw a state machine for napi_struct:

```
netif_napi_add()
    → state: SCHED=1, NPSVC=1 (disabled, not schedulable)

napi_enable()               ← peer.c:58, called after peer fully initialized
    → state: SCHED=0, NPSVC=0 (active, schedulable)

napi_schedule() called:
    → if SCHED=0: set SCHED=1, add to poll_list, raise NET_RX_SOFTIRQ
    → if SCHED=1: set MISSED=1, return (no-op)

wg_packet_rx_poll() runs:
    → delivers packets
    → napi_complete_done(): clear SCHED=0, check MISSED
    → if MISSED=1: reschedule immediately

napi_disable()              ← peer.c:120, during peer teardown
    → set DISABLE=1: napi_schedule becomes no-op
    → busy-wait for in-flight poll to complete
    → safe to free peer memory
```

---

## Diagram 7 — Complete data flow with all queues (reference diagram)

### What this diagram shows

Every queue, every state transition, every CPU boundary in the full WireGuard receive pipeline. Use this as a reference for the full system diagram.

### Components in order

```
[NIC hardware]
    ↓ (DMA, hardware interrupt)
[sk_buff allocated in kernel memory]
    ↓
[Stage 1: wg_packet_receive — softirq context, BH priority]
    ├─ validate_header_len()         — check packet is a WireGuard data message
    ├─ wg_index_hashtable_lookup()   — find keypair by key_idx (identifies peer)
    ├─ Phase 1: wg_prev_queue_enqueue(&peer->rx_queue, skb)
    │   → state = UNCRYPTED
    │   → skb inserted at HEAD of peer's linked list (newest position)
    │   → delivery order established here, never changes
    └─ Phase 2: ptr_ring_produce_bh(&wg->decrypt_queue.ring, skb)
        → cpu = wg_cpumask_next_online() — round-robin CPU selection
        → queue_work_on(cpu, packet_crypt_wq, &worker[cpu].work)
        → Worker on selected CPU will wake up and pull from ring

[Global decrypt ring — ptr_ring]
    Shared across all peers, all CPUs
    Producer: Stage 1 (one per incoming packet)
    Consumer: N decrypt workers (one per CPU, WQ_PERCPU)

[Stage 2: wg_packet_decrypt_worker — SCHED_NORMAL, WQ_PERCPU]
  Loop:
    ├─ ptr_ring_consume_bh(&queue->ring)
    │   ├─ spin_lock_bh()    → BH disabled
    │   ├─ pull skb          → skb now in hand
    │   └─ spin_unlock_bh()  → BH enabled ← NET_RX_SOFTIRQ fires here if pending
    ├─ decrypt_packet(skb)
    │   ├─ skb_cow_data()                         — ensure writable (GFP_ATOMIC)
    │   └─ chacha20poly1305_decrypt_sg_inplace()  — ChaCha20-Poly1305 AEAD
    │       ├─ if auth tag valid: return true → state = CRYPTED
    │       └─ if auth tag invalid: return false → state = DEAD
    └─ wg_queue_enqueue_per_peer_rx(skb, state)
        ├─ wg_peer_get()                           — hold reference
        ├─ atomic_set_release(&PACKET_CB(skb)->state, state)  — visible to all CPUs
        ├─ [WITH FIX] read tail, check if head is ready
        └─ napi_schedule(&peer->napi) — if condition passes

[Per-peer RX queue — prev_queue, one per peer]
    Each entry: sk_buff with atomic state (UNCRYPTED / CRYPTED / DEAD)
    Order: fixed at Stage 1 insertion, never reordered
    Producer: Stage 1 (enqueues in arrival order)
    Consumer: Stage 3 ONLY (single consumer guarantee)

[Stage 3: wg_packet_rx_poll — softirq context, BH priority]
  Called via NAPI when NET_RX_SOFTIRQ fires and napi_struct is on poll_list:
    Loop (budget = 64 packets):
        ├─ wg_prev_queue_peek(&peer->rx_queue)
        │   → returns oldest unconsumed packet (tail of linked list)
        ├─ atomic_read_acquire(&PACKET_CB(skb)->state)
        │   ├─ UNCRYPTED → stop loop, exit
        │   ├─ DEAD      → wg_prev_queue_drop_peeked(), free skb, continue loop
        │   └─ CRYPTED   → proceed with delivery
        ├─ counter_validate()                — replay attack prevention
        ├─ wg_packet_consume_data_done()
        │   └─ napi_gro_receive(&peer->napi, skb)  — inject into kernel stack
        └─ work_done++
    After loop:
        └─ if work_done < budget: napi_complete_done() → clear NAPI_STATE_SCHED

[Linux network stack]
    TCP/IP layer receives reassembled packets
```

---

## Notes for drawing

**Color coding suggestion**
- RED / ORANGE: softirq / BH context (Stage 1, Stage 3, any interrupt handler)
- GREEN: SCHED_NORMAL context (Stage 2 decrypt workers)
- BLUE: data structures (queues, napi_struct, sk_buff)
- YELLOW: state transitions (UNCRYPTED → CRYPTED, NAPI_STATE_SCHED set/cleared)
- GREY: the fix (conditional check region)

**Priority levels (draw as vertical axis)**
- TOP: BH/softirq — Stage 1, Stage 3, NET_RX_SOFTIRQ handler
- BOTTOM: SCHED_NORMAL — Stage 2 decrypt workers
- Arrow pointing UP labeled "preemption" — softirq always wins over SCHED_NORMAL

**Parallelism annotations**
- Stage 2: draw N parallel tracks (one per CPU) — they run truly simultaneously
- Stage 3: draw one box per peer — each peer's GRO runs independently, but only one GRO poll per peer at a time (NAPI_STATE_SCHED prevents double-scheduling)
- Stage 1: single thread (UDP socket receive is serialized per socket)

**The two queues side by side — emphasize the difference**
- Global device ring: horizontal, wide, shared, order does not matter
- Per-peer RX queue: vertical, narrow, per-peer, order is sacred

**The fix visualization**
- Draw the same diagram twice (before / after)
- Before: unconditional arrow from "pkt CRYPTED" to "napi_schedule" to "softirq" to "GRO (wasted)"
- After: conditional branch — "head UNCRYPTED?" → NO PATH to napi_schedule; "head CRYPTED?" → normal path
