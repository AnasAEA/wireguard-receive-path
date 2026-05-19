# Code Study Notes — WireGuard + io-wq Source Analysis
# Anas Ait El Hadj · May 2026

> Running notes from reading the actual kernel source.
> Every claim here has a file:line citation.
> This feeds into the meeting with Alain and André (week of May 19).

---

## Sources used

| Repo / file | How obtained | Version |
|---|---|---|
| `linux-source/drivers/net/wireguard/` | curl from `WireGuard/wireguard-linux` `devel` branch | current devel |
| `linux-source/io_uring/io-wq.c` + `io-wq.h` | curl from `torvalds/linux` master | current master |
| `linux-source/kernel/workqueue.c` | curl from `torvalds/linux` master | current master |
| `wireguard-go/device/` | git clone `WireGuard/wireguard-go` | current master |

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

---

## Part 2 — io-wq internals

### Files read
- `io_uring/io-wq.c` (1523 lines)
- `io_uring/io-wq.h`

### 2.1 io-wq worker architecture — NOT the kernel workqueue subsystem

**This is the critical finding for the proxy argument.**

io-wq workers are **kthreads** (kernel threads created via `create_io_thread`), not workqueue workers dispatched via `queue_work_on`.

**File:** `io-wq.c:892–926` — `create_io_worker()`

```c
tsk = create_io_thread(io_wq_worker, worker, NUMA_NO_NODE);
```

`create_io_thread` spawns a kernel thread running `io_wq_worker`. This is the same mechanism as kthreads — not the `alloc_workqueue` / `queue_work_on` path.

The actual worker function is `io_wq_worker` (a kthread function). It pulls work from an internal queue using raw spinlocks (`raw_spin_lock`), not via the kernel workqueue dispatcher.

### 2.2 What `work_struct` is used for in io-wq

`work_struct` appears in io-wq only for **worker creation retry**, not for dispatching I/O work:

**File:** `io-wq.c:924`
```c
INIT_DELAYED_WORK(&worker->work, io_workqueue_create);
```

This is a fallback: when a new kthread cannot be created immediately (e.g., in a context where `create_io_thread` can't be called), io-wq schedules `io_workqueue_create` on the system workqueue. That function then calls `create_io_thread` again.

The primary path for worker creation is `task_work_add()` (`io-wq.c:411`), which attaches work to the io_uring task's task_work list — again, not `queue_work_on`.

**Summary: `queue_work_on` does not appear in io-wq.c at all.** The `work_struct` / `queue_work_on` kernel workqueue API is not part of io-wq's I/O dispatch path.

### 2.3 How io-wq dispatches work — the actual path

```
io_wq_enqueue(wq, work)          io-wq.c (public API)
  └─ io_wq_insert_work()         adds work to per-acct list (raw_spin_lock)
  └─ io_wq_activate_free_worker() wakes an idle kthread worker
       └─ wake_up_process()      standard kthread wake
  └─ io_wq_create_worker()       if no free worker, creates a new kthread
```

Workers are plain kthreads in a pool, woken via `wake_up_process()`. No `queue_work_on` involved.

### 2.4 Bounded vs unbounded workers in io-wq

**File:** `io-wq.h`

```c
IO_WQ_WORK_UNBOUND = 4,   // flag on a work item
```

io-wq has two accounting slots per pool: bounded (for block/file I/O) and unbounded (for socket I/O and char devices). The distinction controls the max worker count cap, not the dispatch mechanism — both types are kthreads.

Socket reads with `IOSQE_ASYNC` → unbounded kthread pool.

---

## Part 3 — wireguard-go pipeline

### Files read
- `wireguard-go/device/receive.go` (536 lines)
- `wireguard-go/device/device.go` (worker pool setup)
- `wireguard-go/device/queueconstants_default.go`

### 3.1 Three-stage goroutine pipeline

| Stage | Goroutine | File:Line | Equivalent to kernel stage |
|---|---|---|---|
| 1 — receive | `RoutineReceiveIncoming` | `receive.go:72` | Stage 1 (de-encapsulation) |
| 2 — decrypt | `RoutineDecryption` | `receive.go:238` | Stage 2 (decryption workqueue) |
| 3 — inject | `RoutineSequentialReceiver` | `receive.go:429` | Stage 3 (GRO/NAPI) |

### 3.2 Decryption pool size

**File:** `device.go:311–316`

```go
cpus := runtime.NumCPU()
for i := 0; i < cpus; i++ {
    go device.RoutineEncryption(i + 1)
    go device.RoutineDecryption(i + 1)
    go device.RoutineHandshake(i + 1)
}
```

`NumCPU()` decryption goroutines, fixed at startup. Comparable to WireGuard's `WQ_PERCPU` (one worker per CPU).

### 3.3 Coordination between Stage 2 and Stage 3

**File:** `receive.go:179` and `receive.go:265`

```go
// RoutineReceiveIncoming — Stage 1
elemsForPeer.Lock()      // locks the container before sending to both channels
peer.queue.inbound.c <- elemsContainer   // → Stage 3
device.queue.decryption.c <- elemsContainer  // → Stage 2

// RoutineDecryption — Stage 2
elemsContainer.Unlock()  // receive.go:265 — signals Stage 3

// RoutineSequentialReceiver — Stage 3
elemsContainer.Lock()    // receive.go:443 — blocks until Stage 2 unlocks
```

Stage 3 blocks on the container mutex until Stage 2 (decryption) finishes. **EoI is structurally impossible**: there is no mechanism by which Stage 3 can preempt Stage 2 mid-execution the way a softirq preempts a workqueue worker.

### 3.4 TUN boundary

**File:** `receive.go:524`

```go
_, err := device.tun.device.Write(bufs, MessageTransportOffsetContent)
```

One `Write()` syscall per batch (not per packet) crossing back into the kernel. This is the user/kernel boundary cost. Any throughput gap vs kernel WireGuard includes this overhead — so the gap is a **lower bound** on workqueue scheduling cost, not an exact measure.

---

## Part 4 — Key findings for the May 19 meeting

### 4.1 The proxy argument is inaccurate as stated

The report and presentation claim: *"io-wq uses work_struct/queue_work_on, same as WireGuard's workqueue."*

**This is wrong.** Source-level evidence:

| | WireGuard `packet_crypt_wq` | io-wq |
|---|---|---|
| Worker type | Kernel workqueue workers (`alloc_workqueue`) | kthreads (`create_io_thread`) |
| Dispatch API | `queue_work_on()` | `wake_up_process()` on kthread |
| Work item type | `work_struct` | `io_wq_work` (internal struct) |
| CPU affinity | `WQ_PERCPU` (pinned per CPU) | Floating (NUMA-aware) |
| `work_struct` usage | Core dispatch mechanism | Only for worker *creation* retry |

André was right to flag this.

### 4.2 The EoI mechanism is confirmed at source level

The complete EoI chain is traceable:
1. `wg_packet_decrypt_worker` runs in `packet_crypt_wq` (SCHED_NORMAL)
2. After decrypting each packet, calls `wg_queue_enqueue_per_peer_rx` → `napi_schedule(&peer->napi)` at `queueing.h:196`
3. `napi_schedule` records the **current CPU** (stale pointer, not live)
4. When BH is re-enabled (at the next spinlock release in `ptr_ring_consume_bh`), pending GRO softirq fires immediately
5. GRO runs at high priority, finds nothing ready, aborts
6. Pinned core saturates; workers migrate; GRO still targets the old recorded core

### 4.3 wireguard-go confirms EoI is design-level, not just implementation

Go goroutines are user-space scheduled. There is no softirq that can preempt a goroutine mid-execution. The mutex coordination between Stage 2 and Stage 3 ensures ordering without any priority inversion. This is the structural difference.

### 4.4 Open question for the meeting

If io-wq is not the right proxy, what is the plan?

Options:
1. **Direct WireGuard measurement only** — drop io-wq as proxy, focus on tracing `wg_packet_decrypt_worker` directly with bpftrace tracepoints (`workqueue_execute_start`, `workqueue_queue_work`)
2. **Rebuild the proxy argument** — io-wq and WireGuard both use bounded kernel thread pools running at SCHED_NORMAL, preemptable by softirqs. The scheduling *behavior* is comparable even if the dispatch mechanism differs. This is a weaker but defensible claim.
3. **Pivot the objective** — broader study of kernel scheduling priority inversion (EoI is one instance of a general pattern). io-wq could illustrate the pattern without claiming it's identical.

The tracepoints identified (`workqueue_queue_work`, `workqueue_execute_start`, `napi_poll`) apply directly to WireGuard's workqueue and don't require io-wq as an intermediary.

---

## Tracepoints confirmed applicable to WireGuard

| Tracepoint | What it measures | Confirmed applicable |
|---|---|---|
| `workqueue_queue_work` | Moment work is enqueued to `packet_crypt_wq` | Yes — fires when `wg_queue_enqueue_per_device_and_peer` submits to `packet_crypt_wq` |
| `workqueue_execute_start` | Moment worker begins executing | Yes — fires at start of `wg_packet_decrypt_worker` |
| `napi_poll` | NAPI/GRO execution | Yes — fires when `wg_packet_rx_poll` runs |

Interval between `workqueue_queue_work` and `workqueue_execute_start` = scheduler latency for the decryption worker. This is directly measurable on the test environment without any proxy.

---

---

## Part 5 — WireGuard work items: complete inventory and blocking analysis

*Added May 18, 2026. New objective from Alain: identify which work items call blocking functions.*

### 5.1 All WireGuard work items

| Work item function | Workqueue | Flags | File:Line |
|---|---|---|---|
| `wg_packet_decrypt_worker` | `packet_crypt_wq` | `WQ_CPU_INTENSIVE\|WQ_MEM_RECLAIM\|WQ_PERCPU` | `receive.c:493` |
| `wg_packet_encrypt_worker` | `packet_crypt_wq` | same | `send.c:287` |
| `wg_packet_handshake_receive_worker` | `handshake_receive_wq` | `WQ_CPU_INTENSIVE\|WQ_FREEZABLE\|WQ_PERCPU` | `receive.c:206` |
| `wg_packet_handshake_send_worker` | `handshake_send_wq` | `WQ_UNBOUND\|WQ_FREEZABLE` | `send.c:46` |
| `wg_packet_tx_worker` | per-peer TX | n/a | `send.c:262` |

How workers are registered: `wg_packet_percpu_multicore_worker_alloc()` in `queueing.c:9` calls `INIT_WORK` for each CPU, binding the worker function to a `multicore_worker` struct. On each enqueue, `queue_work_on(cpu, wq, work)` submits to the specific per-CPU worker.

### 5.2 `wg_packet_decrypt_worker` — no blocking primitives

**File:** `receive.c:493–507`

Call chain inside the worker loop:
```
ptr_ring_consume_bh()           spinlock (spin_lock_bh) — cannot sleep
  └─ decrypt_packet()           receive.c:242
       └─ skb_cow_data()        memory allocation — may fail, does not sleep
       └─ chacha20poly1305_decrypt_sg_inplace()   pure CPU crypto — no locks, no sleep
  └─ wg_queue_enqueue_per_peer_rx()   atomic_set + napi_schedule — no sleep
       └─ napi_schedule()       queueing.h:196 — schedules softirq, no sleep
```

**`decrypt_packet` (receive.c:242–290) confirmed non-blocking:**
- `skb_cow_data` — may do memory allocation (GFP_ATOMIC context, no sleep)
- `chacha20poly1305_decrypt_sg_inplace` — pure software ChaCha20-Poly1305 AEAD, CPU-only, no locks, no sleep
- Replay counter check uses `spin_lock_bh` (not rwsem) — cannot sleep
- No `down_read`, `down_write`, `mutex_lock`, `wait_event`, or `schedule()` anywhere

**Conclusion: `wg_packet_decrypt_worker` does NOT call any blocking functions.** It is a pure CPU-bound worker.

Note: `WQ_CPU_INTENSIVE` flag on `packet_crypt_wq` is specifically designed for this case — it tells the workqueue subsystem that workers will not block, so the per-CPU concurrency limit should not apply. The workqueue can run other work items concurrently on the same CPU.

### 5.3 `wg_packet_encrypt_worker` — same conclusion

**File:** `send.c:287–307`

Same structure as decrypt: `ptr_ring_consume_bh` → `encrypt_packet` (ChaCha20-Poly1305 AEAD) → `wg_queue_enqueue_per_peer_tx`. No blocking primitives.

### 5.4 `wg_packet_handshake_receive_worker` — **BLOCKING CONFIRMED**

**File:** `receive.c:206–218`

Call chain:
```
ptr_ring_consume_bh()                     spinlock — no sleep
  └─ wg_receive_handshake_packet()        receive.c:92
       └─ wg_noise_handshake_consume_initiation()   noise.c:~598
            └─ wait_for_random_bytes()    noise.c:528  ← BLOCKS if CRNG not ready
            └─ down_read(&static_identity->lock)    noise.c:529  ← SLEEPS if held
            └─ down_write(&handshake->lock)         noise.c:530  ← SLEEPS if held
       └─ wg_noise_handshake_consume_response()     noise.c:~678
            └─ down_read(&static_identity->lock)    noise.c:678  ← SLEEPS if held
            └─ down_write(&handshake->lock)         noise.c:679  ← SLEEPS if held
       └─ wg_noise_handshake_begin_session()        noise.c:816
            └─ down_write(&handshake->lock)         noise.c:822  ← SLEEPS if held
```

**`down_read` / `down_write` are rwsemaphore (sleeping lock) operations.** They put the calling thread to sleep if the semaphore is already held. This means `wg_packet_handshake_receive_worker` can block its workqueue thread.

**`wait_for_random_bytes()` (noise.c:528):** blocks until the kernel CSPRNG is initialized. On a freshly booted system, this can cause significant delays for early handshake packets.

**Workqueue this runs in:** `handshake_receive_wq` = `WQ_CPU_INTENSIVE | WQ_FREEZABLE | WQ_PERCPU`. Even though `WQ_CPU_INTENSIVE` is set (meaning the concurrency limit doesn't apply in the normal sense), the thread itself will block when `down_write` sleeps, removing it from active execution entirely until the lock is released.

### 5.5 `wg_packet_handshake_send_worker` — **BLOCKING CONFIRMED**

**File:** `send.c:46–53`

```c
void wg_packet_handshake_send_worker(struct work_struct *work)
{
    struct wg_peer *peer = container_of(work, struct wg_peer,
                         transmit_handshake_work);
    wg_packet_send_handshake_initiation(peer);   → calls into noise.c
}
```

`wg_packet_send_handshake_initiation` calls `wg_noise_handshake_create_initiation` (noise.c:~529):
- `wait_for_random_bytes()` — noise.c:528 — **blocks until CRNG ready**
- `down_read(&handshake->static_identity->lock)` — noise.c:529 — **sleeping lock**
- `down_write(&handshake->lock)` — noise.c:530 — **sleeping lock**

**Workqueue:** `handshake_send_wq` = `WQ_UNBOUND | WQ_FREEZABLE`. This workqueue IS unbound (floating workers), so blocked threads don't pin to a specific CPU. But blocking still degrades throughput by stalling the worker.

### 5.6 Summary: blocking behavior by work item

| Work item | Blocking calls | Impact |
|---|---|---|
| `wg_packet_decrypt_worker` | None | Pure CPU; `WQ_CPU_INTENSIVE` appropriate |
| `wg_packet_encrypt_worker` | None | Pure CPU; `WQ_CPU_INTENSIVE` appropriate |
| `wg_packet_handshake_receive_worker` | `down_read/write` (rwsem), `wait_for_random_bytes` | **Sleeping locks** — thread blocks on lock contention; CRNG wait on startup |
| `wg_packet_handshake_send_worker` | `down_read/write` (rwsem), `wait_for_random_bytes` | Same — `WQ_UNBOUND` so no CPU pinning, but still blocks |

### 5.7 Interpretation: does this explain the performance problem?

The blocking in handshake workers is real but likely **not the primary cause** of the 19.2% throughput ceiling in the paper's scenario (1,000 clients, sustained data transfer). Handshakes happen only at session establishment, not on every data packet. During a sustained benchmark, handshake rate is low compared to data packet rate.

The primary bottleneck in the paper's scenario is EoI in `wg_packet_decrypt_worker` — not blocking, but priority inversion via `napi_schedule`. The data worker itself is non-blocking.

However, the blocking in handshake workers becomes significant under:
- High connection churn (many clients reconnecting frequently)
- Rekeying pressure (sessions expiring every ~3 minutes with ~1000 clients = ~5 rekeying events/second)
- Early boot (CRNG not seeded — `wait_for_random_bytes` stalls all handshakes)

**This is the new research angle Alain wants explored**: characterize how often the handshake workers block, under what conditions, and whether that blocking is an independent contributor to observed latency.

---

## Part 6 — kernel/workqueue.c: concurrency management and blocking behavior

*Added May 19, 2026. Key question: what happens to a `WQ_CPU_INTENSIVE` pool when a thread blocks?*

### 6.1 The `nr_running` counter and concurrency management

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

### 6.2 `WORKER_CPU_INTENSIVE` removes workers from `nr_running`

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

### 6.3 What happens when a worker sleeps (`wq_worker_sleeping`)

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

### 6.4 `kick_pool`: waking idle workers

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

### 6.5 `WQ_MEM_RECLAIM` and the rescuer thread

`WQ_MEM_RECLAIM` (`packet_crypt_wq` has this) guarantees that even under memory pressure, at least one worker will always be available to make progress. It does this by creating a dedicated "rescuer" thread (`workqueue.c:5705–5735`). This is relevant for correctness under memory pressure, not for normal throughput analysis.

### 6.6 `WQ_PERCPU` — what it means for blocked workers

`WQ_PERCPU` (not a standard kernel flag — WireGuard defines its own via `alloc_workqueue`) means workers are pinned to specific CPUs via `queue_work_on(cpu, wq, work)`. When a per-CPU `WQ_CPU_INTENSIVE` worker blocks (e.g., on an rwsem in handshake processing):

1. Worker is already excluded from `nr_running` (set at work start — step 6.2)
2. `wq_worker_sleeping` returns early (step 6.3) — no redundant decrement
3. `kick_pool` was already called when work started (step 6.4) — an idle worker on the same CPU should have been woken
4. But with `WQ_PERCPU`, the replacement worker is bound to the **same CPU**. If there are no idle workers on that CPU, the queue stalls until the sleeping worker wakes.

**This is the key constraint for handshake workers:** `handshake_receive_wq` is `WQ_CPU_INTENSIVE | WQ_PERCPU`. If the per-CPU worker pool has no idle worker ready (e.g., all pre-spawned workers are busy), incoming handshakes on that CPU can queue up while the active worker sleeps on `down_write(&handshake->lock)`.

**`handshake_send_wq` is different:** it's `WQ_UNBOUND | WQ_FREEZABLE`. Unbound workers float across CPUs and are managed by a global unbound pool. When the handshake send worker sleeps, the pool can wake a worker on any CPU — better resilience, but no NUMA/cache locality guarantees.

### 6.7 Auto-detection: dynamic `WQ_CPU_INTENSIVE` promotion

Beyond the static `WQ_CPU_INTENSIVE` flag, the kernel also auto-promotes concurrency-managed workers dynamically via `wq_worker_tick` (`workqueue.c:1499–1538`): if a concurrency-managed worker hogs the CPU for longer than `wq_cpu_intensive_thresh_us` (default: configured at boot via `/sys/module/workqueue/parameters/cpu_intensive_thresh_us`), it is automatically flagged `WORKER_CPU_INTENSIVE` and kicked out of `nr_running`. This prevents long-running work items from blocking shorter ones on the same CPU.

WireGuard's decrypt/encrypt workers use static `WQ_CPU_INTENSIVE`, not the dynamic mechanism — they declare up front that they won't participate in concurrency management.

### 6.8 Summary: implications for WireGuard handshake blocking

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
| 2026-05-15 | `wireguard-go/device/receive.go`, `device.go` | 3-stage goroutine pipeline confirmed; NumCPU decryption workers; EoI impossible by construction |
| 2026-05-15 | `drivers/net/wireguard/receive.c`, `queueing.h`, `device.c` | EoI chain confirmed at source level; napi_schedule stale pointer at queueing.h:196; packet_crypt_wq is WQ_CPU_INTENSIVE\|WQ_PERCPU not WQ_UNBOUND |
| 2026-05-15 | `io_uring/io-wq.c`, `io-wq.h` | **Proxy argument is wrong**: io-wq uses kthreads (create_io_thread), not queue_work_on; work_struct only for worker creation retry |
| 2026-05-18 | `receive.c`, `send.c`, `noise.c`, `queueing.c` | **New objective**: work item inventory + blocking analysis. Decrypt/encrypt workers: non-blocking (pure ChaCha20). Handshake workers: blocking — rwsem (down_read/write) and wait_for_random_bytes |
| 2026-05-19 | `kernel/workqueue.c` | `WQ_CPU_INTENSIVE` removes worker from `nr_running` at work start (not at sleep). Sleeping `WQ_CPU_INTENSIVE` workers do NOT trigger extra `kick_pool` (already NOT_RUNNING). Per-CPU pool + blocked worker = queue stall on that CPU if no idle worker available. `handshake_receive_wq` (PERCPU) more vulnerable than `handshake_send_wq` (UNBOUND). |

---

## Still to read

- [x] `kernel/workqueue.c` — `WQ_CPU_INTENSIVE` effect on concurrency limit; what happens to pool when a thread blocks — **Part 6**
- [ ] `drivers/net/wireguard/peer.c` — per-peer NAPI setup, `netif_napi_add` call
- [ ] io_uring work items — compare blocking behavior for Thursday meeting
