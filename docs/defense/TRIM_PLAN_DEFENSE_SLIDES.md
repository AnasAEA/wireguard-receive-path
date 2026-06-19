# Plan to Trim WireGuard Defense Presentation (13 min → 10 min)
# June 6, 2026

## Objective
The current defense presentation is technically excellent but runs around 13 minutes. For the final academic defense on June 10, the presentation must be strictly **10 minutes maximum**. 

To achieve this, we are consolidating the architectural explanation, tightening the description of the bug, and focusing heavily on the results and the upcoming CloudLab extension. We are reducing the deck from 13 slides to 9 impactful slides.

---

## The Edits: Slide-by-Slide Breakdown

### 1. The Setup: Consolidating Architecture (Slides 3, 4, 5 → New Slide 3 & 4)
**The Problem:** The current deck spends 3.5 minutes and 3 separate slides detailing NAPI, the Workqueue, and GRO individually before even showing how they connect.
**The Edit:** 
*   We will merge the definitions into a single, punchy slide: **"The Three Kernel Engines"**. 
*   We will clearly define the necessary building blocks in 1 minute and 15 seconds:
    *   **NAPI:** The "doorbell" that batches interrupts.
    *   **Workqueues:** The background threads that decrypt in parallel.
    *   **GRO:** The stapler that merges packets to save network stack overhead.
*   We will then use one slide (**"The Pipeline & The Flaw"**) to show how they connect and point directly to the unconditionally called `napi_schedule`.

### 2. The Bug: Tightening the Explanation (Slide 7 → New Slide 5)
**The Problem:** The current explanation of the Execution Order Inversion (EoI) takes 2 full minutes.
**The Edit:** 
*   Keep the core visual (`bug_zoom_en.svg`).
*   Trim the talk track to focus only on the mechanics of the collision: "Workers decrypt out of order in parallel. Worker A finishes packet 5 early and rings the doorbell. GRO wakes up, sees packet 2 (the head) is still encrypted, and goes back to sleep doing nothing." 
*   Deliver the punchline faster: "At 8 cores, 87.5% of wakes are wasted, CPU is destroyed, and the batching optimization falls apart." (Target: 1m 30s).

### 3. The Fix: Keep as is (New Slide 6)
*   The 6-line code snippet is perfect. It demonstrates deep kernel source engagement. 
*   Keep the explanation focused on safety: "We read the consumer cursor (`tail`). If it's not ready, skip the wake. It's lock-free and safe." (Target: 1m).

### 4. The Experiments: Splitting Setup from Results (New Slides 7 & 8)
**The Problem:** Currently, the M1 setup and the results are somewhat blended.
**The Edit:**
*   Create a brief 30-second slide (**"Experimental Setup"**) to quickly establish credibility: Apple M1, Linux namespaces, and `bpftrace`.
*   Dedicate a full 1m 30s slide (**"Results: Polls Down, Batches Up"**) to the numbers.
*   Emphasize the *mechanism confirmation*: At 8 peers, wasted polls dropped 22%, and batch size went up from 8.7 to 9.6.
*   Briefly state *why* throughput was flat (M1 loopback cannot bottleneck the CPU).

### 5. The Conclusion: Integrating the Internship Extension (Slide 10 & 11 → New Slide 9)
**The Problem:** The "What's next" and "Summary" slides take 1.5 minutes and feel slightly separated from the reality that the internship is ongoing.
**The Edit:**
*   Merge into a single **"Conclusion & Next Steps"** slide.
*   Summarize the win: Found the root cause, fixed it with 6 lines, reduced wasted polls by 22%.
*   Transition directly into the extended internship goals (CloudLab): "My internship continues through July. The immediate next step is CloudLab—real x86 hardware, 25Gbps NICs. We will measure the raw throughput unlocked by this efficiency and try combining our conditional trigger with the SYSTOR paper's dedicated workqueue fix." (Target: 1m).

---

## Pacing Summary & Buffer
*   **Slide 1: Title** (15s)
*   **Slide 2: Context & The Problem** (45s)
*   **Slide 3: The Three Kernel Engines** (1m 15s)
*   **Slide 4: The Pipeline & The Flaw** (1m 15s)
*   **Slide 5: The Bug: Execution Order Inversion** (1m 30s)
*   **Slide 6: The Fix: 6 Lines of Code** (1m)
*   **Slide 7: Experimental Setup** (30s)
*   **Slide 8: Results: Polls Down, Batches Up** (1m 30s)
*   **Slide 9: Conclusion & Next Steps** (1m)

**Total Scripted Time:** ~9 minutes.
**Buffer:** ~1 minute for natural pauses, transitions, and comfortable pacing.