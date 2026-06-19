# Defense Q&A Prep — WireGuard Execution Order Inversion

> Soutenance: **June 10, 2026, 16h–16h30, salle F117**
> Anas Ait El Hadj — Inria KrakOS · supervisors Alain Tchana, André Freyssinet

A quick-reference sheet for the live questions. Part 1 is the "vitals" to have
on the tip of your tongue. Part 2 is anticipated questions with crisp answers.

---

## Part 1 — Vitals (memorize these)

| Item | Value |
|------|-------|
| **Test platform** | Apple M1 Pro (ARM64, 8 cores), Fedora Asahi Remix 42 |
| **Test kernel** | `6.19.13-400.asahi.fc44.aarch64+16k` |
| **x86 cross-check** | Linux v6.1.1 (source read for portability, not benchmarked) |
| **WireGuard** | in-kernel since Linux **5.6** (2020); author Jason A. Donenfeld |
| **Data crypto** | **ChaCha20-Poly1305** (RFC 8439) |
| **Handshake crypto** | Curve25519 (Noise) + **BLAKE2s** hashing |
| **Decrypt workqueue** | `packet_crypt_wq` — `WQ_CPU_INTENSIVE \| WQ_MEM_RECLAIM \| WQ_PERCPU` (`device.c:346`) |
| **The bug trigger** | unconditional `napi_schedule(&peer->napi)` at **`queueing.h:196`** |
| **Poll function** | `wg_packet_rx_poll` (`receive.c:438`), returns `work_done` |
| **Decrypt worker** | `wg_packet_decrypt_worker` (`receive.c:493`) |
| **Internal GRO** | `napi_gro_receive` (`receive.c:411`) |
| **Paper** | Mounah *et al.*, SYSTOR 2025 |
| **Paper's headline** | 19.2 % of 25 Gbps line rate at 1,000 clients |
| **Paper's fix** | move GRO to a dedicated workqueue → **4.7×** throughput, 46 % tail-latency cut |

### The fix (6 lines, before `napi_schedule`)
```c
tail = READ_ONCE(peer->rx_queue.tail);
if (tail == (struct sk_buff *)&peer->rx_queue.empty ||
    atomic_read(&PACKET_CB(tail)->state) != PACKET_STATE_UNCRYPTED)
        napi_schedule(&peer->napi);     // otherwise: skip
```

### Results (M1, loopback, 5 runs each)
| peers | wasted/s (stock → patched) | batch (stock → patched) | Δ wasted |
|------:|:--------------------------:|:-----------------------:|:--------:|
| 1  | 42,638 → 38,872 | 3.1 → 3.3  | −8.8 %  |
| 4  | 33,652 → 30,512 | 14.2 → 15.0 | −9.3 %  |
| 8  | 64,318 → 50,217 | 8.7 → 9.6  | **−21.9 %** |
| 16 | 50,788 → 44,480 | 9.9 → 11.6 | −12.4 % |
| 32 | 64,987 → 51,553 | 7.7 → 8.9  | **−20.7 %** |

---

## Part 2 — Anticipated questions

### Mechanism & understanding

**Q: In one sentence, what is the Execution Order Inversion?**
Decryption finishes out of order across cores, but the code wakes the delivery
poll after *every* completion — so the poll usually finds the head of the
ordered queue still encrypted and delivers nothing.

**Q: Why does the order get inverted?**
The per-CPU workqueue decrypts packets in parallel, one worker per core. The core
handling packet 5 can finish before the core handling packet 2. Delivery, though,
must be in order (the per-peer queue is drained head-first), so completion order
≠ delivery order.

**Q: Why is a wasted poll actually expensive?**
Two costs. (1) A full softirq pass that delivers zero packets — pure CPU waste.
(2) Because the head wasn't ready, GRO had nothing to staple, so batching
collapses and every later packet pays the per-packet stack-traversal cost.

**Q: What's the 1/N intuition?**
With N cores decrypting concurrently, the next-due packet is the first to finish
with probability ~1/N. So the majority of wakes are premature; the waste grows
with N (and with peer count). The report models the expected wasted polls per
batch as ≈ (N−1)/2.

**Q: Why can't decryption just run in the softirq?**
Softirqs run in bottom-half context — they can't sleep and shouldn't run long
work. ChaCha20-Poly1305 is CPU-heavy, so it's delegated to the workqueue
(`WQ_CPU_INTENSIVE`). That delegation is *correct*; the bug is only in the
wake-up trigger.

**Q: What does `napi_schedule` actually do?**
It does **not** run the poll. It sets a flag and raises `NET_RX_SOFTIRQ`; the
poll (`wg_packet_rx_poll`) runs shortly after, at the next BH re-enable point
(the `spin_unlock_bh` in the worker loop).

### The fix & correctness

**Q: Why is the lock-free read safe?**
`rx_queue.tail` is written by a single consumer (the poll itself). A worker only
*reads* it as a hint. There's no concurrent writer to race with.

**Q: What if the read is stale?**
Worst case: we skip a wake we should have done. NAPI's internal *MISSED*
mechanism re-runs the poll if a schedule lands while one is in flight, and the
worker that finishes the head will issue its own wake. **No packet is ever
stranded** — staleness costs at most a tiny latency, never correctness.

**Q: Is this just the paper's fix again?**
No — orthogonal. The paper makes each wasted poll *cheaper* (moves GRO off the
hot softirq). Mine makes wasted polls *less frequent* (don't fire when the head
isn't ready). They stack: fewer wakes, and the remaining ones cheaper.

**Q: Could you over-suppress and starve delivery?**
No. The guard only skips when the head is still `UNCRYPTED`. The moment the head
worker finishes, its `atomic_set_release` makes the state visible and that worker
wakes the poll. Liveness is preserved.

### Methodology & measurements

**Q: How do you measure "wasted polls"?**
`bpftrace` kretprobe on `wg_packet_rx_poll`, histogram of the return value
(`work_done`). `work_done == 0` = a wasted poll. The EoI signature is a spike in
bucket 0; the fix should collapse that bucket and shift mass to >1.

**Q: How is the multi-peer load generated?**
Linux network namespaces over loopback — N peers, each its own tunnel. 5 runs per
configuration, variance controlled, metrics read in-kernel (bpftrace) and with
`perf stat`.

**Q: Why is throughput flat in your results?**
Loopback never saturates `NET_RX_SOFTIRQ` — on the M1, ChaCha20 is fast enough
that the softirq isn't the bottleneck. The paper's throughput collapse needs a
real NIC pushing faster than workers can drain. So I measure the *mechanism*
(wasted polls, batch size), which is architecture-independent, not raw Gbps.

**Q: Then how do you know the fix helps throughput at all?**
I don't claim a throughput number — I claim the *cause* is reduced: 9–22 % fewer
wasted polls and larger GRO batches. Whether that converts to X % throughput on a
saturated NIC is exactly the CloudLab next step.

### Limitations & honesty

**Q: Biggest threat to validity?**
Single platform (ARM, loopback). No saturated-NIC throughput, no x86 numbers yet.
The mechanism evidence is solid; the end-to-end performance claim is future work.

**Q: Why ARM and not x86?**
The dev environment is an M1 (Fedora Asahi). I read the x86/v6.1 source to confirm
the trigger is identical across arches, but didn't benchmark x86. CloudLab (x86,
25 G NIC) is reserved for that.

**Q: Did you upstream the patch?**
Not yet — it's an internship prototype. Upstreaming would need the saturated-NIC
validation and a discussion on the WireGuard list.

### Related work / positioning

**Q: Why not just use kernel bypass (XDP, DPDK, netmap)?**
Those trade kernel security/isolation for speed. WireGuard deliberately stays
in-kernel to inherit the networking stack's guarantees and interoperate. The EoI
is a consequence of that in-kernel design — fixing it in-kernel preserves the
properties that motivate WireGuard in the first place.

**Q: How does this relate to io_uring (the original framing)?**
The internship started from an io_uring "io-wq vs WireGuard workqueue" analogy.
At source level that proxy is dead — io-wq uses `create_io_thread` kthreads, not
`queue_work_on`. The blocking-function analysis redirected to WireGuard's actual
workqueue, where the EoI lives.

### Forward-looking

**Q: What's the *better* fix you mention?**
The current guard wakes on the first ready packet — a one-packet poll gets no GRO
benefit. A batching-aware trigger would wake only when waking *pays off*, which
needs measuring poll overhead vs. delivery + copy-to-userspace cost.

**Q: What would you do with more time?**
1) CloudLab x86 saturated-NIC throughput. 2) The batching-aware trigger.
3) Combine with the SYSTOR dedicated-workqueue fix and measure the additive gain.

---

## Curveballs (stay calm, short answers)

- **"Is 6 lines really a contribution?"** — The value is the *diagnosis*: showing
  at source level that the prior fix is incomplete and the root cause is the
  trigger. The 6 lines are the minimal expression of that insight.
- **"Couldn't the scheduler fix this?"** — No; it's not a scheduling-fairness
  problem. The wake is logically premature regardless of which core runs it.
- **"What about packet reordering / correctness of delivery?"** — Untouched. The
  ordered per-peer queue still drains head-first; I only change *when* the poll
  is woken, not the delivery order.
- **"Why does peer count amplify it?"** — More peers → more concurrent workers →
  more out-of-order completions → more premature wakes. Matches the table (8 and
  32 peers show the biggest reduction).
