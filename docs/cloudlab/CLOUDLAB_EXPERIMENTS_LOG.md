# CloudLab Experiments — Log / Findings

> The readable record of the CloudLab receive-path campaign: what question was tested,
> what ran, what was observed, what it meant, what was decided next. The full unedited
> chronological notebook (every run, error and dead end, newest-first) is preserved in
> [`CLOUDLAB_EXPERIMENTS_LOG_RAW.md`](CLOUDLAB_EXPERIMENTS_LOG_RAW.md); the polished
> synthesis is [`RECEIVE_PATH_FINDINGS.md`](RECEIVE_PATH_FINDINGS.md); runnable next
> steps are in [`CLOUDLAB_NEXT_STEPS.md`](CLOUDLAB_NEXT_STEPS.md).
> Author: Anas Ait El Hadj · Inria KrakOS (LIG).

---

## 0. Current status — read this first (2026-07-07)

The CloudLab campaign answered the main question.

- **The two-sided WireGuard fix is real**: it halves wasted polls on real 10G hardware
  (~27% → ~14%, stable from 8 to 64 peers).
- **But those wasted polls are too cheap to produce a visible CPU or latency win on
  c220g2.** Phase A (sub-saturation, 64 runs) is a clean CPU null; latency shows only a
  noisy, power-state-confounded trend and is not claimed.
- **Phase B showed the mechanism is dose-responsive**: the fix removes 56% of the waste
  on fast crypto and 89% when decrypt is slowed to 10 µs/packet — exactly as predicted —
  yet CPU and latency still do not move.
- **E10 measured why, directly**: baseline's *entire* wasted-poll budget is ~0.022
  cores-equivalent, about 100× below the ±2 CE run-to-run noise floor. The null is now a
  measurement, not an inference. *The fix removes many events, but not many cycles.*
- **E11 found a different latency opportunity**: the head packet waits ~50–100 µs to
  *get* decrypted (10–20× its own decrypt time, insensitive to injected decrypt delay) —
  it queues behind other packets / waits for worker scheduling. This motivates a future
  **head-priority / decrypt-order steering** idea, pending one more measurement.

Remaining work: (1) the ~20-line `wg_diag` per-episode classifier to separate real
head-blocked stalls from empty-queue gaps, then re-run E11; (2) the `headwake`
reliability soak; (3) confirm with Alain/André whether the paper's `gro_wq` combined-fix
deliverable is still required; (4) final write-up.

## 1. The story in one paragraph

We brought the M1-loopback EoI finding to real 10G hardware expecting to validate a
throughput fix, and instead learned — in order — that throughput was never the fix's to
give (the NIC's IP-only flow hash funnelled everything onto one core; fixing *that*
gave ×2.2), that the original one-sided fix does nothing on a real NIC but a two-sided
version (suppress the wasted re-poll *and* gate its regeneration) reliably halves wasted
polls, that this saved work is invisible to users because the whole waste budget is a
hundredth of the measurement noise (measured at the cycle level, twice, with independent
instruments), and finally that the latency cost of the EoI lives somewhere the wake-side
fix cannot reach: the head packet waiting tens of microseconds for its *turn* to be
decrypted — which is a scheduling problem, and the evidence-backed candidate for the
next-stage fix.

## 2. Glossary

| Term | Meaning |
|---|---|
| **EoI** | Execution Order Inversion: packets decrypt in parallel and finish out of order, but delivery must be in order, so the delivery poll often finds the queue head not ready. |
| **wasted poll** | A NAPI poll (`wg_packet_rx_poll`) that delivers zero packets (`retval==0`) — it ran, found the head not deliverable, and exited. |
| **MISSED re-poll** | The kernel's self-rescheduled poll: a wake arriving *during* a poll sets a MISSED flag that forces another poll right after — the main source of wasted polls (95–99.7%). |
| **fresh wake** | A wasted poll started by a brand-new `napi_schedule` (not a MISSED re-poll) — how waste "regenerates" when only one side of the fix is on. |
| **`off`** | Baseline WireGuard behavior (also called *stock* in old entries; all knobs 0). |
| **`wg_supp`** | Consumer-side suppression: at poll end, if the head is still encrypted, clear MISSED so the kernel parks instead of re-polling. (Old name: `move`.) |
| **`wg_headwake`** | Producer-side gate: a decrypt completion only calls `napi_schedule` if the *head* is ready. (Old name: `root`.) |
| **`both` / two-sided fix** | `wg_supp` + `wg_headwake` together — each side catches the waste the other leaks. |
| **`sdfn`** | NIC receive-hash setting that adds UDP ports to the flow hash, spreading tunnels across RX queues/cores (default hashes IPs only → one core). |
| **CE (cores-equivalent)** | CPU time normalized by wall time: 0.5 CE = half a core busy continuously during the window; 8 CE = eight full cores. |
| **p99 / tail latency** | The 99th-percentile round-trip time of a request/response probe — the "worst moments" a user feels. |
| **`wg_decrypt_delay_ns`** | A knob injecting a busy-wait into each decrypt, emulating slower crypto without touching poll cost. |
| **stall episode** | The interval from the first wasted poll after a productive one to the next productive poll on the same NAPI — how long delivery stayed blocked. |
| **Phase A / Phase B** | The sub-saturation CPU+latency campaign / the decrypt-delay sensitivity sweep. |
| **E10 / E11** | Direct cost accounting (cycles and durations) / stall-gap steering-bound measurement. |
| **srcversion** | The kernel module build fingerprint recorded in every CSV row (`EA06EE82…` = the two-sided composable build). |

## 3. Main results, by research question

### Q1 — What limited throughput on c220g2? (Answer: NIC flow placement, not WireGuard)

The first CloudLab surprise was that the fix was never going to move throughput: the
receiver was capped at ~4.1 Gb/s with **one core at 100% (97% softirq) and 39 cores
idle**. The NIC's default flow hash uses only IP addresses; all tunnels to the same
endpoint IP land on one RX queue, hence one core. Adding the UDP ports to the hash is a
single `ethtool` command:

| NIC hash | Throughput | Cores receiving |
|---|---|---|
| `sd` (IPs only — the funnel) | 4.1 Gb/s | 1 (at 100%) |
| `sdfn` (+ UDP ports) | **9.0 Gb/s (×2.2)** | 8 (~55% each) |

Reverified on three separate instantiations. **Consequence: saturated throughput is the
wrong yardstick for judging the EoI fix**, and all subsequent campaigns run in the
`sdfn` spread regime. *(Fil rouge: parallelism is both the cause of the EoI bug and the
cure for throughput.)* Figure: `../meetings/figures/fig_spread.png`.

### Q2 — Does the two-sided fix remove wasted polls? (Answer: yes, ~half, stably)

The original M1 "six-line" producer-side fix alone is a **null on real hardware** (see
Appendix C — at wake time the bell is usually already ringing). Alain's 2026-06-25
insight: the consumer-side suppress cancels a wasted re-poll but the wake *regenerates*
through the producer path — so compose both sides. Peer sweep, `sdfn` spread
(`data/cloudlab/twosided_peersweep_20260626.csv`):

| pairs | `off` | consumer only | producer only | **two-sided (`both`)** |
|---|---|---|---|---|
| 8  | 27.0% | 25.8% | 15.4% | **14.8%** |
| 16 | 27.3% | 26.1% | 15.9% | **13.8%** |
| 32 | 26.8% | 25.1% | 15.0% | **13.1%** |
| 64 | 27.5% | 25.3% | 15.4% | **14.4%** |

Three readings: the two sides are **additive** (consumer alone ~2 pts, producer most,
together best); the **regeneration is visible in the counters** (consumer-only raises
the fresh-wake share of waste from ~3% to ~6%; adding the producer gate drops it to
~1%); and the reduction is **flat from 8 to 64 peers** — the M1 "grows with peers"
effect does not reproduce on real hardware (Appendix C), but the halving is solid.
Mechanism verification: in-module counters show `wg_supp` fires correctly in **96%** of
its target cases and reads exactly 0 with the fix off — the null results that follow are
not "a fix that doesn't fire". Figure: `fig_twosided_peers.png`.

### Q3 — Does the saved work show up as CPU or latency under sub-saturation? (Answer: no — clean null)

Phase A design: peer 0 carries *only* a latency probe (sockperf ping-pong); peers 1–7
carry a capped bulk load; conditions `off` vs `both` × target loads 0/2/4/6 Gb/s × 8
reps, order fully randomized — 64 runs (`subsat_20260701_0609.csv`).

- **Fair comparison, verified per run**: off-vs-both actual load matches within ≤3.4%
  (≤1.2% at 4/6 Gb/s) — `both` does not throttle throughput.
- **CPU: clean null.** Three independent lenses (softirq / system+IRQ / total busy CE)
  all indistinguishable at every load: deltas −4.7%…+1.6%, mixed signs, p≈0.4–1.0.
- **Latency: inconclusive and confounded.** `both` trends 7–8% lower on p99 at 2 and
  4 Gb/s but not significantly (p≈0.37–0.71, IQRs overlap), and the tail is *worst at
  the lowest nonzero bulk load* (~1.5 ms at 1.1 Gb/s vs ~1.0 ms at 3.1; 0-load floor
  ~370 µs) — the wrong direction for queueing, the classic signature of C-states under
  `schedutil`. Not claimed.

Figures: `fig_subsat_cpu.png`, `fig_subsat_latency.png`. Aborted-start CSVs
(`subsat_20260701_0400/0605`) kept as methodology provenance — the 0400 rows carry the
`REJECT_load_dev` flags that motivated per-run load verification.

### Q4 — Does the fix get stronger when decrypt is slower? (Answer: yes, strongly — but still no user-visible payoff)

Phase B injects a per-packet busy-wait into decrypt (`wg_decrypt_delay_ns`) under the
same capped-load, single-window design (`decsweep_20260706_0321.csv`, 50/50 runs valid):

| injected delay | `off` wastes | `both` wastes | fix removes |
|---:|---:|---:|---:|
| 0 µs | 34.4% | 15.2% | **56%** of the waste |
| 1 µs | 34.7% | 12.8% | 63% |
| 2 µs | 34.8% | 12.0% | 66% |
| 5 µs | 33.3% | 7.5% | 78% |
| 10 µs | 34.6% | **3.8%** | **89%** |

Baseline stays flat (~34% — the waste is structural, not a speed artifact) while the fix
improves monotonically with tight IQRs: **a dose-response**, the cleanest mechanistic
result of the project. The head stays encrypted longer ⇒ more gateable wakes, exactly
the model's prediction. Yet CPU deltas stay mixed-sign at every delay and p99 stays
mixed — even at a decrypt:poll cost ratio of ~10:1. (Suggestive only, not claimed:
10–30× fewer TCP retransmits with the fix at 5–10 µs; n=5, high variance.) The earlier
"stock waste rises to ~44%" observation was an uncapped-load collapse artifact
(Appendix C). Figures: `fig_decsweep_wasted.png`, `fig_decsweep_cpu.png`.

### Q5 — Where did the "missing cycles" go? (Answer: they were never there — measured)

The paradox — remove up to 89% of a wasted operation, gain nothing — dissolved under
direct measurement (E10), with two independent instruments in separate windows:

- **bpftrace duration sums**: a wasted poll costs **1.14–1.36 µs** in-regime (the cost
  model said ~1.0; kretprobe overhead makes this an upper bound). Baseline's ~500k
  wasted polls per 30 s window total **657–694 ms of CPU = 0.022 CE**; `both` cuts that
  to 0.001–0.005 CE.
- **perf cycle attribution**: the entire poll+wake machinery (`wg_packet_rx_poll`
  including its *useful* work + `napi_complete_done` + `__napi_schedule`) is **<0.7% of
  all busy cycles** in every condition.

Against the ±2 CE noise floor, the full reclaimable budget (~0.02 CE) is **~100×
below** — removing all of it is invisible by construction. The cycles are in per-packet
delivery, decrypt workers, TCP/IP and userspace, not in polls. **"The fix removes many
events, but not many cycles."** There is also a structural reason latency cannot move:
the wake-side fix never makes any packet *deliverable earlier* — the head is delivered
when its decrypt finishes, which the fix does not touch. Bonus observation: with the fix
on, polls are fewer but longer (15 → 23 µs avg) — deliveries consolidate into bigger
batches, the M1 GRO-batch effect on real hardware. Per-cell data provenance: §7.

### Q6 — Is there another latency opportunity? (Answer: probably — head-priority steering, one measurement away)

E11 measured how long delivery stays blocked when a poll finds the head not ready
(stall episodes, baseline, delays 0/2/5/10 µs). The surprise:

- The bulk of stalls sit at **32–128 µs ≈ 10–20× T_decrypt** (~5 µs), and the median
  **does not grow** when +10 µs of decrypt delay is injected. If decrypt time dominated
  the stall, it would follow the delay. It doesn't.
- Interpretation: the head is not slow to *decrypt* — it is slow to *get decrypted*:
  queued behind other packets on its worker CPU or waiting for the kworker to be
  scheduled (matches the bimodal Δ_complete ~5 µs / ~100 µs in the cost model).
- This is a different problem from the one the current fix solves, and it is the one a
  **head-priority / decrypt-order steering** scheme (the next free CPU takes the current
  head, instead of FIFO on its assigned worker) would attack — and unlike the wake-side
  fix, it *would* deliver packets earlier.

Honest bounds (the probe cannot tell a blocked-head stall from an empty-queue gap —
~46% of wasted polls are empty-queue; the ms-scale population, ~6% of episodes, is
inter-burst idle and excluded):

```text
raw stall gap                      = upper bound on delivery-blocked time
× UNCRYPTED-head fraction (~54%)   = upper bound on relevant head stalls
− decrypt floor                    = conservative recoverable steering excess
```

Result: **typically ~30–90 µs recoverable, tail population 200–800 µs** — above the
agreed "not worth it" band (5–20 µs), tail beyond the "go" threshold (100 µs), but the
head-vs-empty classification is unresolved. **Decision: do not implement steering yet;
implement the ~20-line `wg_diag` per-episode classifier first**, then re-run E11
classified. Figure: `fig_e11_stall_fr.png` (budget figure: `fig_e10_budget_fr.png`).
