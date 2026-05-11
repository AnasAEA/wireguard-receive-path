# Alain Presentation — Detailed Plan
# Anas Ait El Hadj · KrakOS / Inria · May 2026

---

## 1. Situation Analysis

### What this presentation actually is

Alain asked for "a presentation on io_uring to show you understand the subject." On the surface that's a content request. Underneath it's a credibility check after a part-time period where he had no visibility into what you were doing. He almost pulled out. You convinced him to stay. Now he wants proof.

This means: if the presentation is technically shallow, it confirms his original concern. If it's technically deep but disconnected (io_uring for its own sake, with no clear link to the research problem), it looks like you missed the point. The presentation has to do two things simultaneously — show depth AND show that the depth is in service of something.

### What Alain knows coming in

- He assigned the Mounah et al. paper and knows the research well — it comes from his team. He knows EoI in more detail than you do.
- He knows io_uring exists but may not know its internals at the level you've studied.
- He has zero visibility into your day-to-day work during the part-time.
- He knows André acknowledged that the objectives weren't set clearly.

### What he needs to leave with

1. Confidence that you understand io_uring at a researcher level, not a tutorial level
2. Awareness that you did real hands-on work (cat_uring, udp_read.rs, bpftrace instrumentation)
3. A clear sense that you understand the connection between io_uring and his WireGuard work
4. An opening to align on the full-time objectives — he needs to feel like a co-author of the plan, not a reviewer

### The objective problem

André said the internship objectives weren't set clearly. That's both a risk and an opportunity for this presentation. Risk: if you present the three-phase plan as fixed, Alain may push back or redirect. Opportunity: presenting the plan as a proposal explicitly invites his input, which makes him a stakeholder rather than a skeptic.

Slide 7 (scope) is not a status update. It's an alignment moment.

---

## 2. Goals — Ranked

1. **Prove technical depth on io_uring** — specifically: you understand the three paths, why io-wq exists, when it activates, how it dispatches work, why IORING_FEAT_NO_IOWAIT changed things, and why IOSQE_ASYNC is the key flag for socket workloads
2. **Show the proxy argument clearly** — io-wq uses work_struct/queue_work_on, same as WireGuard's workqueue. This is the intellectual contribution of the part-time phase: establishing why io_uring is a valid proxy
3. **Make the experiments concrete** — real numbers (132 µs vs 3.7 µs, 4 ctx switches, 0 vs 4096 workers). These prove you actually ran code, not just read papers.
4. **Open the objectives conversation** — not present a plan, invite alignment on one
5. **Don't be defensive** — don't explain the part-time absence, just show the work

---

## 3. Slide-by-Slide Plan

Total: 7 slides, ~18 minutes. Revised order based on what Alain actually wants: get to the io_uring depth fast, reveal the proxy connection as a payoff after the deep dive, not as a bridge before it. Each slide has: goal, visual, key points, what to say, what NOT to say, time.

Revised time allocation: Context (1 min) → EoI (2 min) → io_uring architecture (4 min) → io-wq internals (4 min) → proxy argument (2 min) → experiments (3 min) → scope (2 min).

---

### Slide 1 — Context: The Problem
**Time:** 1 min

**Goal:** Establish the stakes. One number. Don't over-explain — Alain wrote the paper.

**Visual:**
- Two horizontal bars: 25 Gbps (full width, grey) and 4.8 Gbps (narrow, gold/red)
- Label: "19.2% of available bandwidth"
- Below: small WireGuard logo / Linux kernel badge — "implemented directly in the kernel"

**Key points:**
- 25 Gbps link, 1,000 clients, 4.8 Gbps received
- Not hardware. Not configuration. A scheduling bug in the kernel.
- The specific mechanisms behind that 80% loss have not been measured directly.

**Say:** Let the bar chart speak. One or two sentences. Do not re-explain EoI here.

**Do NOT say:** "As we know from the paper..." in a way that sounds like you're summarizing it back to him. He knows the work.

---

### Slide 2 — WireGuard Reception Pipeline & EoI
**Time:** 2 min

**Goal:** Show you understand the mechanism at code level, not just conceptually.

**Visual:**
- Three-stage pipeline diagram (horizontal, left to right):
  - Stage 1: "De-encapsulation" — UDP receive handler — grey tag: "interrupt context"
  - Stage 2: "Decryption" — workqueue workers — gold tag: "SCHED_NORMAL"
  - Stage 3: "GRO" — softirq/NAPI — red tag: "HIGH PRIORITY"
- Arrow from Stage 3 looping back to interrupt Stage 2 (the EoI arrow)
- Below the pipeline: two CPU bars — one at 94% (red), others at 20% (grey)

**Key points:**
- spin_unlock_bh is a compound operation: releases the spinlock AND calls local_bh_enable() on the local CPU. Any pending softirq — including GRO — fires immediately at the unlock site.
- GRO finds nothing ready, aborts.
- napi_schedule() pins GRO to the CPU last used by a decryption worker — stale pointer, not a live load query. As that core saturates, workers migrate away. Next burst still targets the same recorded core.
- The imbalance self-reinforces on every burst.
- Fix: move GRO to workqueue (same priority as decryption) → 4.7× throughput, 46% tail latency reduction.

**Say:** Walk through the pipeline slowly. Point at spin_unlock_bh. Explain "stale pointer" explicitly — this is the detail that shows you read the code, not just the abstract.

**Do NOT say:** Anything that sounds like you're explaining his paper to him. Frame it as "here's my understanding of the mechanism."

---

### Slide 3 — io_uring Architecture: The Three Paths
**Time:** 4 min

**Goal:** Prove you understand io_uring internals at architecture level, not tutorial level. Don't rush this — if Alain engages with questions here, let it happen. That conversation shows depth better than any prepared answer.

**Visual:**
- io_uring ring diagram: SQ ring (submission), CQ ring (completion), kernel processes in between
- Below: three branching paths from a submitted SQE:
  - Path 1: "Inline" — data available immediately, completes in io_uring_enter()
  - Path 2: "io-wq offload" — IOSQE_ASYNC, or forced blocking — dispatches work_struct
  - Path 3: "Poll wakeup" — EAGAIN → vfs_poll() registration, no thread spawned
- Highlight Path 3 as the default for sockets. Highlight Path 2 as the relevant path.

**Key points:**
- Since kernel 5.18: IORING_FEAT_NO_IOWAIT routes buffered file reads through Path 1. io-wq never activates for file reads on modern kernels. Classic articles are obsolete.
- Socket reads: default is Path 3 (poll). io-wq only activates when IOSQE_ASYNC is set explicitly.
- Consequence: the workqueue overhead lives exclusively on the socket path.

**Say:** "The first thing I found experimentally is that the io-wq path I care about is NOT the default. On modern kernels, file reads never reach io-wq at all. You have to force it on the socket path with a flag most articles don't mention."

---

### Slide 4 — io_uring Worker Pool: io-wq Internals
**Time:** 4 min

**Goal:** The deepest slide. Show you understand the worker pool mechanics — bounded vs unbounded, dispatch path, what controls worker spawning. This is where the real depth lives.

**Visual:**
- io-wq structure diagram:
  - "Bounded workers" — block devices, regular files (one per CPU)
  - "Unbounded workers" — sockets, char devices (dynamic)
  - Worker lifecycle: IDLE → RUNNING → IDLE (with work_struct dispatch shown)
- Small code block (monospace, dark):
  ```c
  io_wq_enqueue(wq, work);  /* Path 2 entry */
  queue_work_on(cpu, wq, &work->work);  /* dispatch */
  ```

**Key points:**
- Sockets use unbounded workers (dynamic pool). Bounded workers are one per CPU for block/file I/O.
- Without IOSQE_ASYNC: socket read → non-blocking attempt → EAGAIN → vfs_poll() wakeup registration. Zero workers spawned.
- With IOSQE_ASYNC: skips the non-blocking attempt, goes straight to io-wq. One worker per in-flight request.
- Worker cap: IORING_REGISTER_IOWQ_MAX_WORKERS. RLIMIT_NPROC and cgroup pids.max can cause retry loops that burn a CPU core.
- The dispatch path: work_struct enqueued via queue_work_on — same call as the Linux workqueue subsystem.

**Say:** "The default socket path never touches io-wq. You have to know which flag forces it, and you have to know what caps the workers to avoid burning a core in a retry loop. That's the level of detail you need before you can use this as a measurement tool."

---

### Slide 5 — The Architectural Connection
**Time:** 2 min

**Goal:** Not a bridge to justify the proxy — a payoff. After seeing io-wq in detail, reveal the connection to WireGuard as something you discovered. Researchers respond to "here's what I found" differently than "here's why my methodology is valid."

**Visual:**
- Two boxes side by side:
  - Left: "io-wq (io_uring internal worker pool)"
  - Right: "WireGuard decryption workqueue"
  - Both connected below to a shared label: "work_struct / queue_work_on" (monospace)
- Left box: tag "single machine, controlled"
- Right box: tag "multi-machine, live network"
- Simple, minimal — let the shared primitive be the visual focus.

**Key points:**
- io-wq uses the exact same kernel dispatch primitives as WireGuard's workqueue: work_struct and queue_work_on.
- Scheduling behavior observable on io-wq — worker dispatch latency, CPU migrations, context switches — reflects the same mechanisms governing WireGuard's decryption workers.
- The tracepoints for measuring io-wq (workqueue_queue_work, workqueue_execute_start) apply to WireGuard without modification.

**Say:** "Once I understood io-wq at this level, I realized it uses the exact same kernel primitives as WireGuard's workqueue. That's not a design choice I made — it's an architectural fact. It means everything I can measure here transfers directly."

**Do NOT say:** "This is why I chose io_uring as a proxy." Frame it as discovery, not justification.

---

### Slide 6 — What I Built: Experiments & Results
**Time:** 3 min

**Goal:** Make the work tangible. Concrete numbers. Actual code. Actual tracepoints.

**Visual — Two panels:**

**Left panel — cat_uring:**
- Label: "cat_uring — 372 lines C, no liburing, raw io_uring"
- bpftrace instrumentation diagram (simplified: tracepoint → log → result)
- Numbers in monospace:
  ```
  Warm cache:   3.7 µs
  Cold cache:  132 µs  (×35.9)
  ctx switches:  4  per cold read
  CPU migrations: 1  per cold read
  io_uring_queue_async_work: 0 fires
  ```
- Bottom: "IORING_FEAT_NO_IOWAIT confirmed — file path ruled out"

**Right panel — udp_read.rs:**
- Label: "udp_read.rs — Cloudflare reproducer, Rust"
- Two-row table (monospace):
  ```
  Without IOSQE_ASYNC:  0 workers / 4096 SQEs
  With    IOSQE_ASYNC:  4096 workers / 4096 SQEs
  ```
- Bottom: "io-wq overhead observable and controllable on socket path"

**Below both:** Tracepoints identified for Phase 2:
- workqueue_queue_work — dispatch latency
- workqueue_execute_start — queue-to-execution interval
- napi_poll — NAPI-side measurement

**Say:** "These two experiments answer two questions: which path is relevant for WireGuard (socket, not file), and whether I can control when io-wq activates (yes, with IOSQE_ASYNC). The tracepoints are already identified and tested — they apply to WireGuard without modification."

**Do NOT say:** Just describe what you read. Point at specific numbers. "4 context switches per cold file read" — say that out loud.

---

### Slide 7 — Full-Time Scope: A Proposal
**Time:** 2.5 min

**Goal:** Open the objectives conversation. NOT presenting a fixed plan.

**Visual:**
- Three horizontal phases (minimal, clean):
  - Phase 1: Reproduce — "4.8 Gbps baseline, <10% variance"
  - Phase 2: Attribute — "workqueue_queue_work / workqueue_execute_start / napi_poll"
  - Phase 3: Compare — "kernel WireGuard vs wireguard-go — lower bound on workqueue cost"
- Below, separate box: "Pending — WireGuard test environment (Brice Ekane / Teo Pisenti)"

**Say:**
"This is my current understanding of what the full-time phase should look like. Reproduce comes first — without a reliable baseline, any measurement is noise. Attribution is the core contribution. The wireguard-go comparison provides an upper bound on what's possible without EoI.

What I want to make sure is that this matches what you have in mind. Are there angles here that should be different? Is there a part of the problem you think I'm underweighting?"

**The critical move:** Stop talking. Let Alain respond. This slide is a question, not a status update.

---

## 4. The io_uring Deep Dive — What "Depth" Means Here

Alain will judge depth by whether you can answer questions like:

- "Why does IORING_FEAT_NO_IOWAIT matter for your proxy?" → File path no longer exercises io-wq. If you'd used file reads as your proxy, you'd be measuring nothing.
- "What's the difference between bounded and unbounded workers?" → Bounded: block/regular file I/O, one per CPU. Unbounded: sockets/char devices, dynamic. WireGuard-relevant = unbounded.
- "Why does IOSQE_ASYNC force io-wq on the socket path?" → Default socket path: non-blocking attempt → EAGAIN → vfs_poll registration. IOSQE_ASYNC skips the non-blocking attempt and goes directly to io-wq. Forces the work_struct dispatch path.
- "What's the relationship between io-wq and the kernel workqueue subsystem?" → io-wq is a separate implementation (not the generic workqueue subsystem), but it uses the same fundamental primitives: work_struct and queue_work_on. The scheduling behavior is therefore comparable.

Know these cold. If Alain pushes on any of them, answer directly — don't pivot or hedge.

---

## 5. Dangerous Questions

**"What exactly did you do during the part-time period?"**
Don't list papers you read. Lead with what you built.
> "I built cat_uring — a raw io_uring file reader, 372 lines, no liburing — and instrumented it with bpftrace to confirm IORING_FEAT_NO_IOWAIT. Then I reproduced the Cloudflare worker pool experiment in Rust to confirm IOSQE_ASYNC behavior on the socket path. Those are on slide 6."

**"How does this connect to my paper?"**
> "The fix in your paper moves GRO to a workqueue using work_struct and queue_work_on. io-wq uses the same primitives. The tracepoints I've identified for measuring io-wq overhead — workqueue_queue_work, workqueue_execute_start — apply to WireGuard's decryption workers without modification. That's the proxy."

**"What are the full-time objectives exactly?"**
Don't pretend they're fixed. This is the Slide 7 conversation.
> "That's what I want to align with you on today. My proposal is the three phases on the last slide, but I want to make sure that matches your vision for the internship."

**"Have you looked at the kernel workqueue code?"**
If you haven't: "Not in detail yet — I've focused on the io-wq dispatch path and the tracepoints. Looking at the kernel workqueue source is something I planned to do during Phase 2 setup."

---

## 6. Tone & Dynamics

**Walk in confident.** You did real work. You have concrete numbers. You understand the mechanism at code level (spin_unlock_bh, stale pointer, napi_schedule). That's more than most students at this stage.

**Don't apologize for the part-time.** Don't explain why you weren't visible. Show the work and let it speak.

**On Slide 7 — actually stop talking.** The instinct will be to fill the silence. Don't. Ask the question and wait for his response. This is the moment that converts a one-sided presentation into a real conversation.

**If he corrects something:** "You're right, I hadn't thought of it that way." Don't defend the mistake. Move on.

**If he asks something you don't know:** "I haven't dug into that yet. I can." Never bluff.

---

## 7. What Success Looks Like

The presentation worked if, at the end of Slide 7:
- Alain starts asking questions about the full-time plan (not about whether you understand io_uring)
- He offers his own view of what Phase 2 or 3 should look like
- He mentions Brice or Teo without being asked

If you get those, the credibility check passed and the relationship is reset.

---

## 8. Numbers to Know Cold

| Fact | Number |
|---|---|
| WireGuard RX throughput (1000 clients, 25 Gbps) | 4.8 Gbps = 19.2% |
| Workqueue fix — throughput gain | 4.7× |
| Workqueue fix — tail latency reduction | 46% |
| Kthread fix — throughput gain | 4× |
| Kthread fix — tail latency reduction | 65% |
| Saturated core | 94% |
| Other cores | 20% |
| cat_uring — warm cache | 3.7 µs |
| cat_uring — cold cache | 132 µs (×35.9) |
| cat_uring — ctx switches per cold read | 4 |
| cat_uring — CPU migrations per cold read | 1 |
| udp_read.rs — workers without IOSQE_ASYNC | 0 |
| udp_read.rs — workers with IOSQE_ASYNC | 4,096 |
| cat_uring — lines of C | 372 (no liburing) |
