# Speaker Notes — EoI Proof WireGuard
# Meeting with Alain & André — Thursday May 21, 9h

---

## Slide 1 — Title

The goal of this presentation is to prove, line by line in the Linux kernel source code, that there is an execution order inversion in WireGuard's receive pipeline. I am not going to cite the paper by Mounah et al. as an authority — I am going to show the exact mechanism in the code itself, so that every single claim can be independently verified in the source tree.

The bug belongs to a well-known class in concurrent programming: one stage of a pipeline wakes up a downstream stage before the data that stage needs is ready. The consequence here is not a crash or data corruption — it is a silent, self-reinforcing performance loss that caps throughput at 19.2% of the NIC's theoretical line rate.

---

## Slide 2 — The Claim

Before diving into the code, I want to state precisely what we are trying to prove.

WireGuard's receive pipeline has three stages. Stage 1 is the UDP receive handler, running in softirq context — a high-priority deferred interrupt. Stage 2 is the decryption worker, running inside a workqueue at `SCHED_NORMAL` priority, the same as any regular user process. Stage 3 is GRO — Generic Receive Offload — which reassembles packets and injects them into the networking stack. GRO also runs in softirq context, meaning it runs at a higher priority than Stage 2 and can preempt it at any time.

The problem: Stage 2, after decrypting each packet, calls `napi_schedule` to wake up Stage 3. But by the time Stage 3 actually fires, the data it needs to make progress is often not ready — because another CPU is still decrypting the packet sitting at the head of the ordered queue. Stage 3 preempts Stage 2, finds a blocked queue, and returns immediately without doing anything useful. The entire CPU cycle is wasted.

The three numbers on the right summarize the diagnosis: the saturated core runs at 94% CPU utilization, only 19.2% of expected throughput gets through, and with 1,000 clients — the scenario from the paper — each peer has its own NAPI instance capable of triggering this cycle independently.

---

## Slide 3 — Step 1: Each peer has its own NAPI instance

The first thing to understand is the fundamental architecture: in WireGuard, every remote peer — every machine connected through the tunnel — has its own `napi_struct` instance. This is not a trivial implementation detail. It is an architectural choice with direct consequences for the bug.

`netif_napi_add` is the function that registers this instance with the kernel's networking subsystem. It takes three important arguments: the WireGuard network device (`wg->dev`), the peer's NAPI structure (`&peer->napi`), and the poll function to call when GRO needs to run (`wg_packet_rx_poll`). From this point on, any call to `napi_schedule(&peer->napi)` from any CPU in the system will place this peer onto the current CPU's poll list and raise the `NET_RX_SOFTIRQ` flag.

`napi_enable`, called immediately after, is the activation gate: until this call, the NAPI structure exists in memory but cannot be scheduled. `napi_enable` clears the `NAPI_STATE_SCHED` and `NAPI_STATE_NPSVC` bits that had been artificially set by `netif_napi_add` to keep it disabled. After this call, the peer is fully operational.

Why design it as one NAPI per peer rather than one shared NAPI for the entire device? Two reasons: first, ordering isolation — each peer's packet stream must be delivered in order independently of all other peers. Second, parallelism — with a single shared NAPI, all peers would serialize through one poll function. With per-peer NAPIs, different peers can be processed simultaneously on different CPUs.

The direct consequence for the bug: with 1,000 peers, there are 1,000 independent NAPI instances, each capable of independently binding to and saturating a CPU.

---

## Slide 4 — Step 2: The decryption workqueue

The `packet_crypt_wq` workqueue is created with three flags that completely define its scheduling behavior.

`WQ_PERCPU` means one worker thread is allocated and pinned per CPU. There is no migration — the worker on CPU 3 stays on CPU 3. Under heavy load, if that worker is busy or blocked, no replacement worker is created on that CPU. This pinning is essential to understanding the saturation: the worker and GRO end up on the same core with no way out.

`WQ_CPU_INTENSIVE` removes these workers from the kernel's concurrency counter (`nr_running`). Normally, the workqueue manager limits the number of simultaneously running workers on a CPU to avoid over-subscription. With `WQ_CPU_INTENSIVE`, these workers are excluded from that mechanism — they can run as long as they need without the kernel creating additional workers to compensate. This is appropriate here because ChaCha20-Poly1305 decryption is pure CPU computation, with no waiting and no sleeping locks.

But — and this is the critical point — `WQ_CPU_INTENSIVE` does nothing about preemptibility. These workers run at `SCHED_NORMAL`. Softirqs run above the regular process scheduler entirely. A softirq can always preempt a `SCHED_NORMAL` worker, `WQ_CPU_INTENSIVE` or not.

---

## Slide 5 — Step 3: The decrypt worker loop

The loop is straightforward in structure: `ptr_ring_consume_bh` pulls one encrypted packet from the global ring, `decrypt_packet` performs the ChaCha20-Poly1305 decryption in pure CPU computation, and then `wg_queue_enqueue_per_peer_rx` places the packet in the peer's queue and schedules GRO.

What is important to understand is that this loop runs continuously as long as there are packets in the ring. It does not process a batch and stop — it is a tight loop that chains packets one after another. The `cond_resched` at the end is a voluntary yield to the scheduler, but only if the scheduler has flagged this thread as needing to yield (`need_resched`). Under heavy load, this yield may never trigger.

The EoI is not inside `decrypt_packet` — decryption itself is not the problem. The EoI comes from the fact that `wg_queue_enqueue_per_peer_rx` is called on every iteration, which means `napi_schedule` is called for every single packet decrypted. Between every two consecutive iterations, GRO can fire.

---

## Slide 6 — Step 4: ptr_ring_consume_bh — the BH disable/enable cycle

This function is the key to understanding the exact timing of the EoI. It pulls a pointer from the ring buffer protected by a spinlock, but it does so by disabling bottom halves — softirqs — for the duration of the access.

`spin_lock_bh` disables softirqs on the current CPU in addition to acquiring the spinlock. During this window, no softirq can run on this CPU, even if the `NET_RX_SOFTIRQ` flag has been raised. `__ptr_ring_consume` pulls the packet from the ring. `spin_unlock_bh` releases the spinlock and re-enables softirqs by calling `local_bh_enable()`. And this is where everything happens: if a softirq was pending — meaning `NET_RX_SOFTIRQ` had been raised while BH was disabled, or just before — it runs immediately inside `spin_unlock_bh`, before the function even returns to its caller.

This means GRO does not fire "after the loop" or "at the end of the worker's batch". It fires inside `ptr_ring_consume_bh`, between two iterations of the loop. Specifically: the `napi_schedule` from iteration N raises the flag, and that flag is consumed at the `spin_unlock_bh` inside `ptr_ring_consume_bh` of iteration N+1.

---

## Slide 7 — Step 5: wg_queue_enqueue_per_peer_rx — the EoI trigger

This small inline function is the heart of the bug. It does two things in order.

First, `atomic_set_release` marks the just-decrypted packet as `PACKET_STATE_CRYPTED`. The "release" in `atomic_set_release` is a memory barrier that guarantees this write is visible to all other CPUs before any subsequent operation. The current packet is genuinely ready.

Second, `napi_schedule(&peer->napi)` raises the `NET_RX_SOFTIRQ` flag. It does not immediately trigger GRO — it records that GRO should run, and binds the NAPI poll to the current CPU via `this_cpu_ptr(&softnet_data)`.

The important subtlety: GRO is not going to fail because of the packet we just marked CRYPTED. That packet is ready. GRO is going to fail because of the head of the peer's ordered queue, which belongs to a different packet being decrypted on a different CPU. The problem is not this packet — it is the global state of the ordered queue.

---

## Slide 8 — Step 6: napi_schedule — CPU binding

`napi_schedule` is a simple function that calls `__napi_schedule`, which in turn calls `____napi_schedule` — with three underscores — passing it `this_cpu_ptr(&softnet_data)`.

`this_cpu_ptr` is a kernel macro that returns a pointer to the per-CPU variable `softnet_data` on the CPU executing this instruction at this exact moment. `softnet_data` is the structure holding the NAPI poll list for that CPU. `list_add_tail` adds the peer's NAPI structure to that list. `__raise_softirq_irqoff` raises the `NET_RX_SOFTIRQ` bit in the CPU's softirq mask.

Two important consequences of this mechanism. First: the NAPI poll is bound to the CPU that executed `napi_schedule`. If the decryption worker is running on CPU 3, GRO will fire on CPU 3 — not on a less loaded CPU, not on the most efficient CPU available. On CPU 3.

Second: once `NAPI_STATE_SCHED` is set, any subsequent call to `napi_schedule` for the same peer from any CPU is a no-op — `napi_schedule_prep` returns false. A peer can only be scheduled once at a time. This means if other workers are decrypting packets for the same peer concurrently, their `napi_schedule` calls have no effect until the current poll completes.

---

## Slide 9 — Step 7: When the softirq actually fires

This slide shows the precise timing of the EoI, iteration by iteration.

During iteration N: the worker pulls packet N via `ptr_ring_consume_bh` — which re-enables BH at the end. Decryption runs. Packet N is marked CRYPTED. `napi_schedule` raises `NET_RX_SOFTIRQ`. But at this point, BH has already been re-enabled since `ptr_ring_consume_bh` returned. `napi_schedule` uses `local_irq_save/restore`, not `local_bh_enable` — so the softirq does not fire here.

During iteration N+1: the worker enters `ptr_ring_consume_bh` to pull packet N+1. `spin_lock_bh` disables BH. `__ptr_ring_consume` pulls packet N+1 from the ring. `spin_unlock_bh` re-enables BH via `local_bh_enable`. At this moment, `NET_RX_SOFTIRQ` is pending from iteration N. `do_softirq` runs. `wg_packet_rx_poll` executes, finds the queue head UNCRYPTED, exits. The worker resumes — but it has not yet processed packet N+1. It has only just pulled it from the ring.

GRO slots itself between the moment a packet is pulled from the ring and the moment the worker begins processing it. The interleaving happens at per-packet granularity, not per-batch.

---

## Slide 10 — Step 8: Why GRO finds nothing — the ordering constraint

`wg_packet_rx_poll` walks the peer's receive queue strictly from the head, in order, and stops the moment it encounters a packet in state `PACKET_STATE_UNCRYPTED`.

The reason for this constraint is fundamental: TCP requires in-order delivery. If packet 0 has not been decrypted yet but packet 1 has, GRO cannot deliver packet 1 to the network stack before packet 0 — that would break TCP's sequence numbering and cause unnecessary retransmissions.

Under concurrent load with multiple CPUs decrypting in parallel, the queue almost always looks like this: the head is UNCRYPTED — because some CPU is still working on it — and CRYPTED packets are waiting behind it. GRO arrives, inspects the head, sees UNCRYPTED, and exits immediately. `work_done` stays at zero. `napi_complete_done` is called, which clears `NAPI_STATE_SCHED` and releases the NAPI for the next scheduling.

One important detail I verified in the source: DEAD packets — those whose authentication failed — do not block the poll. The code at `receive.c:458` detects them and continues with a `goto next`. Only UNCRYPTED blocks. So this is not a problem of corrupted packets — it is structural, inherent to the concurrent decryption design.

---

## Slide 11 — Step 9: Self-reinforcing saturation

This slide explains why the problem does not resolve itself under load.

On CPU X, the decryption worker is pinned by `WQ_PERCPU`. It cannot migrate. GRO is also pinned to CPU X because `napi_schedule` captured `this_cpu_ptr` while the worker was running on CPU X. Both are locked to the same core.

The self-reinforcing loop: the worker decrypts a packet, calls `napi_schedule`, and moves to the next iteration. That next iteration starts with `ptr_ring_consume_bh`, whose `spin_unlock_bh` re-enables BH and fires GRO. GRO runs at high priority, preempts the worker, inspects the queue, finds the head UNCRYPTED, exits. The worker resumes. Decrypts a packet. `napi_schedule`. `ptr_ring_consume_bh`. GRO. Nothing. Resume. This repeats for every packet in the ring.

The result measured in the paper is striking: 94% CPU utilization on the saturated core. That core is not idle — it is extremely busy. But the majority of its time is spent in useless GRO polls rather than in productive decryption. Hence the 19.2% effective throughput.

---

## Slide 12 — Summary: Complete chain, files and lines

This table is the condensed proof. Eleven checkpoints, each with its file and line number in the `linux-source/` source tree.

I want to highlight two things about this table. First, checkpoints 6 and 7 are on consecutive lines in `queueing.h` — lines 195 and 196. The gap between "mark the packet ready" and "schedule GRO" is literally one line of code. That is where the inversion is born.

Second, checkpoint 9 and checkpoint 4 both point to the same file and line: `ptr_ring.h:371`. That is because it is the same call — `ptr_ring_consume_bh` — that both fires the softirq (via `spin_unlock_bh`) and pulls the next packet from the ring. The site where GRO executes and the site where the next packet becomes available are the same location in the code. The interleaving is unavoidable by construction.

---

## Slide 13 — The fix from the paper

The fix is elegant because it changes exactly one thing: the priority level at which GRO executes.

Instead of calling `napi_schedule(&peer->napi)` — which schedules the NAPI poll as a high-priority softirq on the current CPU — the fix calls `queue_work_on(cpu, gro_wq, &peer->rx_work)`, dispatching `wg_packet_rx_poll` as a work item on a dedicated workqueue running at `SCHED_NORMAL`.

Two immediate consequences. First: GRO can no longer preempt the decryption worker — they are at the same `SCHED_NORMAL` priority. The scheduler controls their ordering, and typically the worker continues until it voluntarily yields or its time quantum expires. Second: GRO can be dispatched to a different CPU than the worker — breaking the co-pinning on the same core.

The tight coupling between Stage 2 and Stage 3 is broken. The preemption cycle disappears. And the measured result: a 4.7× throughput increase and 46% tail latency reduction. The pipeline topology did not change — same three stages, same data, same hardware. Only the execution priority of GRO changed.

---
