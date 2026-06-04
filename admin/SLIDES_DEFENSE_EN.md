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
(15s) Hello — I'm Anas, my internship is about a performance problem in
WireGuard's receive path. Three goals: understand the mechanism, locate the
bug, evaluate the fix.
-->

---

## Context

- **WireGuard**: modern VPN in the Linux kernel — fast for one client, but on a **server with 1,000 clients** it reaches only **19.2% of line rate**.
- Prior work (Mounah *et al.*, SYSTOR 2025): found the cause (**Execution Order Inversion**) and proposed a fix → **4.7× throughput**. But that fix is **incomplete**: it makes each wasted operation cheaper, not less frequent.
- **My work**: understand the receive pipeline from the source code, identify the root cause of the EoI, and fix it at the trigger.

<!--
(45s) WireGuard is fast for one client. The problem is on the server side:
1,000 clients, 25 Gbps, and throughput collapses to 19% of what the link can
carry because one CPU saturates. Prior work named this the EoI and proposed a
fix: 4.7× improvement. But the root cause is still there — my work targets it.
-->

---

## The map — three stages

![width:1100px](../diagrams/slide_pipeline_teaser_en.svg)

<span class="small">Three engines, three execution contexts. We unpack each one, then we'll see exactly where it breaks.</span>

<!--
(30s) Here is the packet's journey — three stages, three execution contexts.
I'll explain each one, and then we'll see where the problem is. Keep this map
in mind.
-->

---

## Stage 1 — the peer and NAPI

![height:420px](../diagrams/slide_napi_en.svg)

<span class="small">Each client = one **peer** with its **own ordered queue** and its **own NAPI**. One shared decryption workshop for all peers.</span>

<!--
(1m30s) First, the peer. Each client at the other end of the tunnel is a
"peer" — it has its own queue that records arrival order, and its own NAPI.
NAPI is the batching mechanism: instead of an interrupt for every packet, the
kernel rings once, mutes the doorbell, and collects in batches. The important
point: calling napi_schedule does NOT run the poll immediately — it just sets
a flag and schedules it for a moment later. And WireGuard builds its own NAPI
per peer, on a virtual interface, woken by hand from the decrypt workers.
Key: one shared decryption workshop, but each peer has its own delivery queue.
This contrast is what will explain why the bug grows with peer count.
-->

---

## Stage 2 — the workqueue

![height:420px](../diagrams/slide_wq_en.svg)

<span class="small">Decryption is too heavy for the softirq → delegated to a **background pool**. One worker per core → decrypts **in parallel** → finishes **out of order**.</span>

<!--
(1m15s) Decryption — ChaCha20-Poly1305 — is too heavy to do in the softirq,
which is borrowed time where you can't linger. So WireGuard delegates it to a
workqueue: background kernel threads that can take their time. There's one
worker per CPU core, so several packets decrypt simultaneously on several cores.
This is fast — but here's the seed of the bug: they finish OUT OF ORDER. The
core handling packet 5 may finish before the one handling packet 2. Each worker,
when done, calls napi_schedule to wake the peer's NAPI.
-->

---

## Stage 3 — GRO

![height:410px](../diagrams/slide_gro_en.svg)

<span class="small">Pushing a packet up the stack has a **fixed cost per packet** → GRO **staples packets into one parcel** → one trip instead of N. WireGuard has **2 fronts**.</span>

<!--
(45s) GRO — Generic Receive Offload — staples consecutive packets of the same
flow into one larger unit before passing them up the stack. The idea: the stack
has a fixed traversal cost per packet, so it's better to pay it once for a batch
of 10 than 10 times for individuals. WireGuard uses GRO at stage 3 to batch the
decrypted packets before delivery. This is what the bug destroys.
-->

---

## Assembled — and where it breaks

![width:1100px](../diagrams/slide_pipeline_en.svg)

<span class="small">The red box: <span class="tag">napi_schedule unconditional</span> — fires after **every** completion, regardless of queue state. This is the problem.</span>

<!--
(45s) The full pipeline. Everything works — until you look at the red box in
the middle. After every decrypted packet, unconditionally, a worker wakes the
NAPI. Not "only if the head is ready". After EVERY one. That's the trigger we
need to look at.
-->

---

## The bug — Execution Order Inversion

![height:430px](../diagrams/bug_zoom_en.svg)

<!--
(2m — this is the core, slow down) Here's why that unconditional wake is a
problem. Two facts together. One: the workqueue decrypts out of order — core 2
finishes packet 5 before core 0 finishes packet 2. Two: after every completion,
napi_schedule fires. So the NAPI wakes, looks at the head of the ordered
queue — packet 2, still encrypted — and returns with work_done = 0. Nothing
delivered. A wasted wake. And worse: because GRO found nothing to batch, the
batching benefit is lost too. The bug wastes CPU AND breaks batching. With N
cores, the head finishes first with probability 1/N — so (N-1)/N wakes are
wasted. The more cores, the worse it gets.

Punchline: "we wake up to deliver, but there's nothing ready at the front."
-->

---

## The fix — 6 lines

**Before** calling `napi_schedule`, check whether the **head of the queue is ready**.

```c
tail = READ_ONCE(peer->rx_queue.tail);
if (tail == (struct sk_buff *)&peer->rx_queue.empty ||
    atomic_read(&PACKET_CB(tail)->state) != PACKET_STATE_UNCRYPTED)
        napi_schedule(&peer->napi);     // otherwise: skip
```

- **Safe:** `tail` written only by the single consumer → no race condition.
- **Worst case:** stale read → skip one wake → the worker finishing the head wakes it then.
- **Effect:** premature wakes disappear → GRO gets full batches back.

<!--
(1m) The fix: six lines. Before waking the NAPI, read the consumer cursor of
the per-peer queue. If the head is still uncrypted, skip the wake — the worker
that finishes the head will do it. Why is it safe? That cursor is written by
only one entity, the poll itself, so reading it from a worker is safe as a
hint. A stale read in the worst case means one missed wake, caught right after
by NAPI's MISSED mechanism. Expected result: premature wakes gone, GRO gets its
batches back.
-->

---

## Results and next steps

**ARM (M1, loopback) — 9–22% fewer wasted polls, batch size up:**

| | 1 peer | 8 peers | 32 peers |
|---|---|---|---|
| Δ wasted polls | −8.8% | **−21.9%** | **−20.7%** |
| Batch size | 3.1 → 3.3 | 8.7 → **9.6** | 7.7 → **8.9** |

- Throughput flat — expected on loopback (ChaCha20 is faster than the link).
- **Honest limit:** the throughput collapse needs a real NIC (25G).
- **Next:** CloudLab (x86, 25G) to measure the throughput gain.
- **Prior fix + our fix are orthogonal** — they can be combined.

<!--
(1m15s) On my M1, in a loopback multi-peer setup, the fix reduces wasted polls
by 9 to 22% — growing with peer count, exactly as the theory predicts. Batch
size rises in every case, which directly shows GRO is woken less often but with
more to do each time. Throughput is flat because on a loopback, ChaCha20 is
fast enough that NET_RX_SOFTIRQ never saturates — the throughput collapse of
the paper requires a real NIC. I have CloudLab access for that next step.
And to be clear: the prior fix (cheaper polls) and our fix (fewer polls) are
independent and can be combined.

Thank you — questions?
-->

---

<!-- _header: "APPENDIX" -->

## Appendix A — one workqueue, per-CPU workers

- **One** workqueue object (`packet_crypt_wq`, `device.c:346`), shared by all peers.
- **Per-CPU = the *workers* are per core**: `queue_work_on(cpu, …)` dispatches each item to a specific core. It is **not** N workqueues.

---

<!-- _header: "APPENDIX" -->

## Appendix B — NAPI lifecycle

`netif_napi_add` → `napi_enable` → `napi_schedule` (sets flag + raises softirq, **nothing runs yet**)
→ `wg_packet_rx_poll` → `napi_complete_done` → `napi_disable` → `netif_napi_del`

The poll runs at the next `spin_unlock_bh` in the worker loop — not immediately.

---

<!-- _header: "APPENDIX" -->

## Appendix C — Full results table

| peers | build | wasted/s | waste% | batch | Δwasted |
|---|---|---|---|---|---|
| 1  | stock / patched | 42,638 / 38,872 | 25.1 / 24.9 | 3.1 / 3.3 | −8.8% |
| 4  | stock / patched | 33,652 / 30,512 | 29.7 / 28.5 | 14.2 / 15.0 | −9.3% |
| 8  | stock / patched | 64,318 / 50,217 | 29.2 / 28.2 | 8.7 / 9.6 | −21.9% |
| 16 | stock / patched | 50,788 / 44,480 | 28.5 / 28.2 | 9.9 / 11.6 | −12.4% |
| 32 | stock / patched | 64,987 / 51,553 | 28.8 / 27.5 | 7.7 / 8.9 | −20.7% |

---

<!-- _header: "APPENDIX" -->

## Appendix D — bpftrace proof

```text
kretprobe:wg_packet_rx_poll { @work_done = lhist(retval, 0, 64, 8); }
```

- **Spike in bucket 0** = wasted wakes (EoI signature).
- The fix must **collapse bucket 0** and shift mass to > 1 (real batches).
