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

### 1.1 The decryption workqueue — `packet_crypt_wq`

**File:** `device.c:346–347`

```c
wg->packet_crypt_wq = alloc_workqueue("wg-crypt-%s",
        WQ_CPU_INTENSIVE | WQ_MEM_RECLAIM | WQ_PERCPU, 0, dev->name);
```

**Flags:**
- `WQ_CPU_INTENSIVE` — workers don't count toward the per-CPU concurrency limit; the scheduler can run other work items concurrently on the same CPU
- `WQ_MEM_RECLAIM` — ensures a rescue worker is always available even under memory pressure
- `WQ_PERCPU` — **one worker per CPU, pinned**. Not floating like `WQ_UNBOUND`.

**Note on WQ_PERCPU:** Our earlier claim that WireGuard uses `WQ_UNBOUND` workers is wrong. It's per-CPU. This is relevant to the proxy argument.

Other workqueues in `device.c`:
- `handshake_receive_wq` → `WQ_CPU_INTENSIVE | WQ_FREEZABLE | WQ_PERCPU` (line 335–336)
- `handshake_send_wq` → `WQ_UNBOUND | WQ_FREEZABLE` (line 341–342)

The decryption path — `packet_crypt_wq` — is the one relevant to EoI and to the paper's results.

### 1.2 The decryption worker function

**File:** `receive.c:492–507`

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

This is the Stage 2 worker. It runs inside the kernel workqueue (`packet_crypt_wq`), at `SCHED_NORMAL` priority.

Key call: `ptr_ring_consume_bh()` — this internally acquires a spinlock with BH disabled (`spin_lock_bh`) and releases it (`spin_unlock_bh`). Releasing BH re-enables softirq processing on the local CPU.

### 1.3 EoI trigger chain — full call sequence

The EoI happens inside the decryption worker loop, triggered by `wg_queue_enqueue_per_peer_rx`:

**File:** `queueing.h:188–197`

```c
static inline void wg_queue_enqueue_per_peer_rx(struct sk_buff *skb,
                                                 enum packet_state state)
{
    struct wg_peer *peer = wg_peer_get(PACKET_PEER(skb));
    atomic_set_release(&PACKET_CB(skb)->state, state);
    napi_schedule(&peer->napi);   // <-- EoI trigger
    wg_peer_put(peer);
}
```

`napi_schedule(&peer->napi)`:
- Records the **current CPU** in the `napi_struct` and marks GRO as pending (softirq)
- This is a **stale pointer**: it stores the CPU that the decryption worker is currently running on, not a live load query
- As the pinned core saturates, workers migrate to other CPUs — but the recorded CPU in `napi_struct` is not updated
- Next burst still targets the same recorded core → self-reinforcing saturation

When the spinlock's BH-disable is released (at the next `spin_unlock_bh` in the ring consume path), any pending softirq — including the just-scheduled GRO — fires immediately on the local CPU. GRO runs in interrupt context, finds no completed packets (decryption isn't done yet), and aborts. This is EoI.

**Complete chain:**

```
wg_packet_decrypt_worker()          receive.c:492
  └─ ptr_ring_consume_bh()          [internal: spin_lock_bh → BH disabled]
  └─ decrypt_packet()               receive.c:501
  └─ wg_queue_enqueue_per_peer_rx() receive.c:503
       └─ napi_schedule()           queueing.h:196   ← EoI trigger: records current CPU
  └─ [BH re-enabled at ring unlock]
       └─ GRO softirq fires         ← preempts worker, finds nothing, aborts
```

### 1.4 NAPI poll handler

**File:** `receive.c:438`

```c
int wg_packet_rx_poll(struct napi_struct *napi, int budget)
{
    struct wg_peer *peer = container_of(napi, struct wg_peer, napi);
    ...
    // loops over per-peer RX queue
    wg_packet_consume_data_done(peer, skb, &endpoint);  // ← calls napi_gro_receive
    ...
    napi_complete_done(napi, work_done);   // receive.c:488
    return work_done;
}
```

`napi_gro_receive(&peer->napi, skb)` is at `receive.c:411` inside `wg_packet_consume_data_done()`.

This is Stage 3. It runs as a softirq (high priority), which is precisely what preempts Stage 2.

### 1.5 How packets enter the decryption workqueue

**File:** `receive.c:524–529` inside `wg_packet_consume_data()`

```c
ret = wg_queue_enqueue_per_device_and_peer(
        &wg->decrypt_queue, &peer->rx_queue, skb,
        wg->packet_crypt_wq);
```

This enqueues to the per-device decrypt queue and submits to `packet_crypt_wq`. The kernel workqueue subsystem then dispatches `wg_packet_decrypt_worker` to a per-CPU worker thread.

### 1.6 The other `spin_unlock_bh` call

**File:** `receive.c:329`

This is inside the replay counter validation function (`wg_noise_received_with_keypair`), not in the primary decryption path. It's a separate lock release protecting the counter backtrack array. Not the EoI site — the EoI happens via `napi_schedule` in `wg_queue_enqueue_per_peer_rx`.

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

## Study log

| Date | Files read | Key finding |
|---|---|---|
| 2026-05-15 | `wireguard-go/device/receive.go`, `device.go` | 3-stage goroutine pipeline confirmed; NumCPU decryption workers; EoI impossible by construction |
| 2026-05-15 | `drivers/net/wireguard/receive.c`, `queueing.h`, `device.c` | EoI chain confirmed at source level; napi_schedule stale pointer at queueing.h:196; packet_crypt_wq is WQ_CPU_INTENSIVE\|WQ_PERCPU not WQ_UNBOUND |
| 2026-05-15 | `io_uring/io-wq.c`, `io-wq.h` | **Proxy argument is wrong**: io-wq uses kthreads (create_io_thread), not queue_work_on; work_struct only for worker creation retry |
| 2026-05-18 | `receive.c`, `send.c`, `noise.c`, `queueing.c` | **New objective**: work item inventory + blocking analysis. Decrypt/encrypt workers: non-blocking (pure ChaCha20). Handshake workers: blocking — rwsem (down_read/write) and wait_for_random_bytes |

---

## Still to read

- [ ] `kernel/workqueue.c` — `WQ_CPU_INTENSIVE` effect on concurrency limit; what happens to pool when a thread blocks
- [ ] `drivers/net/wireguard/peer.c` — per-peer NAPI setup, `netif_napi_add` call
- [ ] io_uring work items — compare blocking behavior for Thursday meeting
