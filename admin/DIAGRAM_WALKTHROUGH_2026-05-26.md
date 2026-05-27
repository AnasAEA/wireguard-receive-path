# Diagram Walkthrough — Meeting May 26, 2026
# Talking points for each diagram, in order

---

## Diagram 1 — Top-level pipeline overview

**What it shows:** the three-stage receive pipeline and where EoI happens.

**What to say:**

"This is the full receive pipeline. Three stages:

- Stage 1 is the UDP receive handler — runs at high priority (BH context), just de-encapsulates packets and queues them.
- Stage 2 is the decrypt workqueue — `packet_crypt_wq`, one worker per CPU (`WQ_PERCPU`), runs at normal scheduler priority (`SCHED_NORMAL`). This is where ChaCha20-Poly1305 decryption happens.
- Stage 3 is GRO — reassembles decrypted packets and delivers them to the Linux network stack. This runs as a softirq, which is high priority.

The right side of the diagram shows the EoI interaction. After every decryption, the worker calls `napi_schedule` at `queueing.h:196`. That raises `NET_RX_SOFTIRQ`. The softirq fires almost immediately — at the very next `spin_unlock_bh` in the decrypt worker's own loop. GRO runs. In most cases it finds nothing ready at the queue head and exits with `work_done = 0`.

The problem is that GRO fires after **every single packet**, unconditionally."

---

## Diagram 2 — The two parallel queues

**What it shows:** the structural separation between the global device ring and the per-peer RX queue, and the two-phase enqueue.

**What to say:**

"This diagram shows the two independent queues — this is fundamental to understanding why the bug exists.

**Global device ring** (`ptr_ring`): one ring for the whole WireGuard device, all peers mixed together. This determines **which CPU decrypts which packet**. Packets are dispatched round-robin via `wg_cpumask_next_online` (`queueing.h:164`).

**Per-peer RX queue** (`prev_queue`): one queue per peer, FIFO by arrival order. This determines **delivery order to the network stack**. GRO walks this queue strictly from the oldest packet.

The two-phase enqueue at `queueing.h:152`:
- Phase 1: insert into per-peer queue, state = UNCRYPTED. Delivery order is fixed here, before any decryption happens.
- Phase 2: insert into global ring, dispatch worker to a CPU. CPU assignment happens here.

These two roles are fully separated. The ordering guarantee is established at enqueue time and never changes. No locks needed — the state field (`UNCRYPTED` → `CRYPTED` / `DEAD`) is the only coordination mechanism."

---

## Diagram 3 — Concurrent decryption and the EoI trigger

**What it shows:** the full scenario — how same-peer packets end up on different CPUs, why GRO fires at the worst moment, and what GRO finds.

**What to say:**

"This is the core scenario. Four packets arrive from the same peer, back to back.

**Top-left panel:** Stage 1 assigns them round-robin — packet 0 to CPU 0, packet 1 to CPU 1, etc. They go into the per-peer queue in order (0, 1, 2, 3). All four start decrypting in parallel.

**Top-right panel (timeline):** CPU 0 was already busy with a previous peer's packet when these four arrived. So it starts decrypting packet 0 *later* than CPUs 1, 2, 3 start theirs. The head packet has a systematic disadvantage. CPU 3 finishes first.

**Bottom-left panel:** CPU 3 finishes, marks packet 3 as CRYPTED, and calls `napi_schedule`. GRO fires. It looks at the queue head — packet 0 — which is still UNCRYPTED. It returns `work_done = 0`. Nothing delivered. One CPU cycle wasted.

**Bottom-right panel:** the GRO poll flowchart. `wg_packet_rx_poll` (`receive.c:451`) — the while loop walks from the head. First packet UNCRYPTED → exits immediately.

The probability that the head finishes first among N concurrent decryptions is 1/N. On 8 cores: 87.5% of `napi_schedule` calls produce zero useful work."

---

## Diagram 4 — The self-reinforcing loop (the bug in detail)

**What it shows:** the exact per-iteration behavior of a decrypt worker — how the wasted GRO invocation is embedded in the worker's own loop.

**What to say:**

"This diagram shows what happens inside CPU 0's decrypt worker on two consecutive iterations.

**Iteration N:** the worker calls `ptr_ring_consume_bh` to pull a packet from the global ring. The `_bh` suffix means it disables bottom-half processing (softirqs) during the ring operation. Then it decrypts the packet. Then it calls `wg_queue_enqueue_per_peer_rx` — which marks the packet CRYPTED and calls `napi_schedule`. Then it calls `ptr_ring_consume_bh` again for the next packet. At the moment of `spin_unlock_bh` — that's when BH gets re-enabled — the pending `NET_RX_SOFTIRQ` fires. GRO runs. Head is UNCRYPTED. `work_done = 0`. Worker resumes.

**Iteration N+1:** same thing. Same waste.

The right side shows the cycle: worker runs → calls `napi_schedule` → softirq fires at BH re-enable → GRO finds nothing → worker resumes → repeat.

This runs for **every single packet**. One core saturates at 94% running this cycle. The other cores are underutilized."

---

## Diagram 5 — The fix: conditional napi_schedule

**What it shows:** the patched `wg_queue_enqueue_per_peer_rx`, two concrete scenarios (head UNCRYPTED and head CRYPTED), the residual limitation, and a before/after comparison.

**What to say:**

"This is the proposed fix — your idea from the meeting.

**Top-left:** the new Step 3. After marking the packet CRYPTED, instead of calling `napi_schedule` immediately, we read `peer->rx_queue.tail` with `READ_ONCE`. That gives us the oldest packet still in the queue — the one GRO would look at first.

- If `tail` is the STUB sentinel (queue boundary) → schedule conservatively.
- If `tail->state == UNCRYPTED` → skip `napi_schedule`. GRO cannot make progress.
- Otherwise → schedule normally.

**Scenario A (top-right):** head is still UNCRYPTED. CPU 3 finishes, checks tail → UNCRYPTED → skips `napi_schedule`. No softirq raised. No GRO invocation. Zero wasted calls.

**Scenario B (bottom-right):** head just became CRYPTED (CPU 0 was the first to finish). CPU 0 checks tail → CRYPTED → calls `napi_schedule`. GRO fires. Delivers packets 0, 1, 2, 3 in one poll. `work_done = 4`. Useful work done.

**Bottom-left:** the residual gap case. After GRO delivers packets 0 and 1 and stops at packet 2 (UNCRYPTED), there is a narrow window between GRO stopping and `napi_complete_done` clearing `NAPI_STATE_SCHED`. If CPU 2 marks packet 2 CRYPTED inside this window, it calls `napi_schedule` — but the flag is still set, so it's a no-op. `napi_complete_done` then clears the flag. Nobody reschedules. Packets 2 and 3 wait for the next arrival.

This is not a correctness problem — the packets are eventually delivered. Under sustained traffic it's invisible. Under bursty traffic it may cause a rare tail latency spike. It's a second-order effect.

**Bottom table:** the before/after comparison. GRO invocations: every millisecond → only when head is non-UNCRYPTED. Wasted polls: 87.5% → eliminated in the dominant case."

---

## Diagram 6 — NAPI per-peer architecture (supporting)

**What it shows:** how NAPI instances are bound to CPUs, the scheduling mechanism under concurrent decryption, and the napi_enable/disable lifecycle.

**What to say:**

"This is a supporting diagram to explain the NAPI mechanics — this came up as an open question from last time.

With 1,000 peers, there are 1,000 independent `napi_struct` instances. Each peer has exactly one — confirmed at `peer.c:57`: `netif_napi_add(wg->dev, &peer->napi, wg_packet_rx_poll)`.

When a worker on CPU 0 calls `napi_schedule(&peer_A->napi)`, the implementation calls `this_cpu_ptr(&softnet_data)` — which captures **the current CPU**, not the best CPU for GRO. It adds the napi_struct to CPU 0's softirq poll list. So GRO runs on whatever CPU happened to finish a packet first, not the CPU with the most progress on that peer's queue.

Under concurrent decryption, multiple CPUs call `napi_schedule` for the same peer. `NAPI_STATE_SCHED` prevents double-scheduling — only the first call wins. If the NAPI is already scheduled and runs, `napi_complete_done` clears `SCHED` and checks `MISSED` — if another call happened while the poll was running, it reschedules immediately.

The lifecycle: `napi_enable` is called at `peer.c:58` after full initialization. `napi_disable` is called at `peer.c:120` during peer teardown — after that, `napi_schedule` is a no-op."

---

## Diagram 7 — Complete data flow reference

**What it shows:** the full end-to-end pipeline with all queues, all scheduling points, and the EoI trigger annotated.

**What to say:**

"This is the full reference diagram — every piece together in one view.

Stage 1 on the left: `wg_packet_receive` in BH context. UDP datagram arrives, header checked, per-peer and global queues populated via the two-phase enqueue.

Stage 2 in the middle: each CPU runs `wg_packet_decrypt_worker`. It consumes from the global ring with `ptr_ring_consume_bh`, decrypts, calls `wg_queue_enqueue_per_peer_rx` — which marks CRYPTED and fires `napi_schedule`. The scheduling point is annotated here.

Stage 3 on the right: `wg_packet_rx_poll` running as `NET_RX_SOFTIRQ`. Walks the per-peer queue, delivers the contiguous run, stops at UNCRYPTED. `napi_gro_receive` passes each packet up to the Linux network stack.

The arrows show where the EoI happens — the `napi_schedule` call in Stage 2 triggering Stage 3 before the per-peer queue is in a deliverable state. The fix sits exactly at that arrow."

---

## Suggested order and pacing

1. Start with **Diagram 1** — big picture, 2 minutes. Gets everyone oriented.
2. **Diagram 2** — the two queues, 3 minutes. This is the structural foundation.
3. **Diagram 3** — the scenario, 4 minutes. This is the argument.
4. **Diagram 4** — the loop, 2 minutes. Reinforces the per-packet trigger.
5. **Diagram 5** — the fix, 5 minutes. Most discussion will happen here.
6. **Diagram 6** — NAPI details, 2 minutes. Only go deep if they ask.
7. **Diagram 7** — reference, 1 minute. "Everything in one view."

Total: ~20 minutes for the diagrams, leaving time for discussion on the diff and next steps.
