# 2-Minute Madness — Script
# Anas Ait El Hadj · Inria KrakOS · April 2026

> Read once before. ~235 words. ~120 wpm. Exactly 2 minutes.
> Point at the slides as noted — the visuals carry the technical weight, the words carry the story.

---

## Slide 1 — Hook (20 sec)

WireGuard is a VPN built directly into the Linux kernel — it's supposed to be fast.
But on a 25-gigabit link with 1,000 clients, it only reaches 4.8 gigabits.
That's 19% of available bandwidth.
It's not a hardware problem. It's not a configuration problem.
It's a scheduling bug buried in the kernel.

*→ Point at the two bars.*

---

## Slide 2 — The Mechanism (40 sec)

The pipeline runs in the wrong order.
Packet reassembly — which should happen last — fires before decryption finishes.

Here's why: decryption runs in a background worker thread at normal priority.
Packet reassembly runs in a high-priority interrupt handler.
A single line of kernel code re-enables that interrupt handler mid-decryption.
So reassembly fires, finds nothing ready, and aborts.
Then it comes back, processes a huge backlog — alone, on one core.
That core hits 94% load. Every other core sits at 20%.

*→ Trace the pipeline with your hand: Stage 1 → Stage 3 fires → Stage 2 blocked.*
*→ Point at the CPU bars.*

Moving reassembly to the same priority level eliminates the inversion — 4.7× throughput gain.

---

## Slide 3 — My Approach (25 sec)

My approach uses io_uring — a modern kernel I/O interface — as a controlled proxy.
Its internal worker pool shares the exact same infrastructure as WireGuard's decryption workers.
I've already instrumented it with kernel tracing tools and confirmed the key behaviors.

*→ Point at the two boxes: io_uring left, WireGuard right.*

io_uring is the testbed. WireGuard is the target.

---

## Slide 4 — Plan (35 sec)

Three phases.

First: reproduce the 4.8-gigabit ceiling reliably — under 10% run-to-run variance.

Second: pin the overhead to specific mechanisms — context switches, CPU migrations,
worker wakeup latency — using bpftrace tracepoints.

Third: compare kernel WireGuard against the Go implementation,
which runs in user space and is immune to kernel interrupt preemption.

*→ Point at the three phases, then the 4.7× number.*

If the hypothesis holds, that 4.7× gain is reproducible.
My job is to prove it — and explain exactly which kernel mechanisms account for every bit of the gap.
