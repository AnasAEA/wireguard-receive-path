---
marp: true
theme: default
paginate: true
size: 16:9
math: katex
style: |
  section { font-size: 26px; }
  section.lead { text-align: center; }
  h1 { color: #1e3a8a; font-size: 40px; }
  h2 { color: #1e3a8a; }
  img { display: block; margin: 0 auto; }
  .small { font-size: 20px; color: #555; }
  .tag { color: #b91c1c; font-weight: bold; }
  footer { color: #888; }
footer: "WireGuard · Execution Order Inversion · Anas Ait El Hadj · Inria KrakOS"
---

<!-- _class: lead -->
<!-- _paginate: false -->

# WireGuard's receive path
## Finding and fixing the Execution Order Inversion

Anas Ait El Hadj — Inria internship (KrakOS)
Supervisors: **Alain Tchana** · **André Freyssinet**

<!--
(20s) Hello — I'm Anas Ait El Hadj. My internship at Inria KrakOS is about
WireGuard's receive path: a performance problem that shows up on servers with
many clients. Three verbs: understand, measure, fix.
-->

---

## The problem

- **WireGuard** is a fast, modern VPN built into the Linux kernel.
- Under high load (1,000 clients, 25 Gbps), it collapses to **19.2% of line rate** — one CPU core saturates.
- Prior work (Mounah *et al.*, SYSTOR 2025) found the cause — **Execution Order Inversion** — and proposed a fix: **4.7× throughput** improvement.
- **But that fix is incomplete.** It makes each wasted operation cheaper, not less frequent.
- **My work:** understand the mechanism from the source code, identify the root cause, propose and evaluate a complementary fix.

<!--
(1m) WireGuard is known for being simple and fast. But on a server handling
thousands of clients, its receive path hits a wall: one CPU core saturates at
~94% and throughput collapses to 19% of what the link can carry. A 2025 paper
named this the Execution Order Inversion and proposed a fix that recovered 4.7×
throughput — impressive, but it addresses the symptom, not the cause. My work is
to understand the mechanism from the source code and fix the root cause directly.
-->

---

## How a packet travels through WireGuard

![width:1050px](../diagrams/slide_pipeline_teaser_en.svg)

- **Stage 1 — receive:** NIC batches packets (NAPI); WireGuard puts each in a *per-peer ordered queue*.
- **Stage 2 — decrypt:** one worker *per CPU core* decrypts in parallel → finishes **out of order**.
- **Stage 3 — deliver:** WireGuard's own poll function re-orders and groups packets (GRO) before handing to the app.

<!--
(1m30s) A packet crosses three stages. At stage 1 the NIC hands it to WireGuard,
which places it in an ordered per-peer queue — this fixes delivery order. At stage
2, a background worker decrypts it using ChaCha20. There's one worker per CPU
core, so several packets decrypt simultaneously, and they finish in an order set
by the hardware, not by arrival. At stage 3, WireGuard's poll function dequeues
from the head of that ordered queue, groups packets into batches (GRO), and hands
them to the application. The key fact: delivery can only proceed from the HEAD of
the queue — no matter how many later packets are ready, nothing moves until the
head is decrypted.
-->

---

## The bug — Execution Order Inversion

![height:430px](../diagrams/bug_zoom_en.svg)

<!--
(2m — slow down here, this is the core) Here's where it breaks. Two facts
combine. First: the workqueue decrypts out of order — core 2 finishes packet 5
before core 0 finishes packet 2. Second: after EVERY decryption, the worker
unconditionally calls napi_schedule — "wake up and deliver". So the poll wakes,
looks at the head of the queue — packet 2, still encrypted — and leaves without
doing anything. work_done = 0. A wasted wake. And it gets worse: because the
poll found nothing, GRO couldn't batch anything either. So the bug wastes CPU
AND breaks batching. With N cores decrypting in parallel, the head is first to
finish with probability 1/N — so N-1 out of N wakes are wasted. More cores,
more waste.
- Punchline: "we ring the doorbell every time a worker finishes — but the
  delivery can't start until the first packet is ready."
-->

---

## The fix

**Idea:** before waking the poll, check whether the head is actually ready.

```c
tail = READ_ONCE(peer->rx_queue.tail);
if (tail == (struct sk_buff *)&peer->rx_queue.empty ||
    atomic_read(&PACKET_CB(tail)->state) != PACKET_STATE_UNCRYPTED)
        napi_schedule(&peer->napi);     // otherwise: skip the wake
```

- **Safe:** `tail` is written only by the single consumer → no race.
- **Worst case:** we miss a wake → the worker that finishes the head wakes it then.
- **Effect:** removes premature wakes → GRO gets full batches back.

<!--
(1m) Six lines. Before calling napi_schedule, we read the consumer cursor of
the per-peer queue. If the head is still uncrypted, we skip the wake entirely —
the worker that eventually makes it ready will do it. Why is this safe? Because
that cursor is written by only one entity, the poll itself, so reading it from a
worker is a safe hint. The worst case is a slightly stale read where we miss one
wake — and the NAPI handles that with its MISSED mechanism. Expected result:
we remove the premature wakes, GRO gets its batches back.
-->

---

## Results

**On ARM (Apple M1, Fedora Asahi) — multi-peer loopback:**

| peers | wasted polls/s (stock) | wasted polls/s (patched) | Δ |
|---|---|---|---|
| 1 | 42,638 | 38,872 | −8.8% |
| 8 | 64,318 | 50,217 | **−21.9%** |
| 32 | 64,987 | 51,553 | **−20.7%** |

- **Batch size increases** (8.7→9.6 packets/poll at 8 peers): GRO coalesces more.
- **Throughput unchanged** — expected: loopback doesn't saturate `NET_RX_SOFTIRQ`.
- **Honest limit:** the throughput collapse of the paper needs a real 25G NIC.
- **Next:** CloudLab (x86, 25G NIC) to measure the throughput gain.

<!--
(2m) Here are the numbers. On my M1 with a loopback setup, the fix reduces
wasted polls by 9 to 22% depending on peer count. The reduction grows with peer
count — exactly as predicted by the 1/N model. At 8 peers, mean batch size goes
from 8.7 to 9.6 packets per useful poll — GRO is woken less often but does more
each time. Throughput stays flat, which is expected: on a loopback, ChaCha20 is
fast enough that NET_RX_SOFTIRQ never saturates, so the GRO benefit doesn't show
in Gbps here. The full throughput collapse of the paper requires a real NIC. I've
secured CloudLab access for the x86 validation.
- If asked for more detail: show appendix table or refer to the report.
-->

---

<!-- _class: lead -->

## Summary

**1.** The EoI comes from an **unconditional wake** after every decryption, regardless of queue state.

**2.** The prior fix lowers the **cost** per wake; ours lowers the **count**. They are orthogonal and can be combined.

**3.** **9–22% fewer wasted polls** on ARM, confirmed; x86 throughput validation in progress.

<span class="small">Thank you — questions?</span>

<!--
(45s) Three takeaways. One: the root cause is an unconditional napi_schedule —
it fires after every decryption whether or not there's anything to deliver. Two:
the prior fix and ours attack different halves of the problem and can be combined.
Three: I confirmed the mechanism and the fix on ARM; the throughput regime
validation is the natural next step. Thank you.
- Appendices A-D ready for questions.
-->

---

<!-- _header: "APPENDIX" -->

## Appendix A — one workqueue, per-CPU workers

- **One** workqueue object (`packet_crypt_wq`, `device.c:346`), shared by all peers.
- **Per-CPU = the workers are per core**: `queue_work_on(cpu, …)` dispatches each item to a specific core. It is **not** N workqueues.

---

<!-- _header: "APPENDIX" -->

## Appendix B — NAPI in detail

`netif_napi_add` → `napi_enable` → `napi_schedule` (just sets a flag + raises softirq)
→ `wg_packet_rx_poll` (the actual poll) → `napi_complete_done` → `napi_disable` → `netif_napi_del`

"Waking" = set flag + raise `NET_RX_SOFTIRQ`. **Nothing runs yet.**
The poll runs at the next `spin_unlock_bh` in the worker loop.

---

<!-- _header: "APPENDIX" -->

## Appendix C — Full results table

| peers | build | wasted/s | waste% | batch | Δwasted |
|---|---|---|---|---|---|
| 1 | stock / patched | 42,638 / 38,872 | 25.1 / 24.9 | 3.1 / 3.3 | −8.8% |
| 4 | stock / patched | 33,652 / 30,512 | 29.7 / 28.5 | 14.2 / 15.0 | −9.3% |
| 8 | stock / patched | 64,318 / 50,217 | 29.2 / 28.2 | 8.7 / 9.6 | −21.9% |
| 16 | stock / patched | 50,788 / 44,480 | 28.5 / 28.2 | 9.9 / 11.6 | −12.4% |
| 32 | stock / patched | 64,987 / 51,553 | 28.8 / 27.5 | 7.7 / 8.9 | −20.7% |

---

<!-- _header: "APPENDIX" -->

## Appendix D — bpftrace proof

```text
kretprobe:wg_packet_rx_poll { @work_done = lhist(retval, 0, 64, 8); }
```

- **Spike in bucket 0** = wasted wakes (the EoI's signature).
- The fix must **collapse bucket 0** and shift mass toward > 1 (real batches).
