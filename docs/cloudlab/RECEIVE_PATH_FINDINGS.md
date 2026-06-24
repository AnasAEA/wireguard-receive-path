# WireGuard receive path on real 10G hardware — findings

> Synthesis of the CloudLab receive-path investigation. The lab notebook with raw runs
> is `CLOUDLAB_EXPERIMENTS_LOG.md`; this is the polished, honest conclusion. Author: Anas
> Ait El Hadj · Inria KrakOS (LIG). Testbed: CloudLab Wisconsin `c220g2`, 2× Xeon
> E5-2660 v3 (40 threads), NIC `enp6s0f1` 10 GbE, kernel 5.15.0-177. Figures live in
> `../meetings/figures/`.

## TL;DR — what we actually found (and what we did not)

1. **The EoI fix does not improve real-world performance.** The Execution-order-Inversion
   wasted-poll inefficiency is real and we can reduce it (by 20–50% depending on the
   variant), but on real hardware that buys **nothing**: throughput, latency, and
   CPU-per-byte are all unchanged. The wasted polls are simply too cheap (~1 µs each).
2. **The one thing that did move throughput is parallelism, and it is a NIC config change,
   not the fix.** The receiver was funnelled onto a single core by the NIC's IP-only flow
   hash; switching the hash to include the UDP ports (`sdfn`) fans the tunnels across 8
   cores and lifts throughput **4.1 → 9.0 Gb/s (×2.2)**, near line rate. This works with
   *stock* WireGuard.
3. **So the deliverable of this phase is a rigorous negative result + a corrected
   hypothesis + identification of the real lever (parallelism).** Not a speedup. (Note:
   on the earlier *M1 loopback* testbed — the graded/defended work — the fix *did* show a
   benefit, e.g. tail latency ~halved at 64 peers; this phase shows that does **not**
   generalise to real 10G hardware, and explains why.)

The rest of this document is the evidence.

## 1. The mechanism (confirmed, single-core AND parallel)

WireGuard decrypts a peer's packets **in parallel across cores** (padata), so they finish
**out of order**, but delivery must be **in order**. The NAPI poll (`wg_packet_rx_poll`)
only consumes from the head of the per-peer queue; if the head isn't decrypted yet the
poll delivers nothing — a **wasted poll**. Stock: **~30–33% of polls are wasted**.

Almost all of them are **MISSED-driven re-polls**: while a poll runs, a decrypt worker
finishing a *non-head* packet calls `napi_schedule`, which is a no-op for starting a poll
but sets `NAPI_STATE_MISSED`; at poll end `napi_complete_done` sees MISSED and forces
another poll that re-finds the same UNCRYPTED head. Measured share of wasted polls that
are MISSED re-polls: **99.7% on one core, 95% in the 8-core spread regime** — the
mechanism is the same under parallelism.

Cost model (Phase C, measured): `C_poll` ≈ 1.0 µs (empty poll), fixed delivery setup
≈ 3.7 µs, `C_deliver` ≈ 1.64 µs/packet, `T_decrypt` ≈ 5–6 µs. The natural MISSED re-poll
fires at median ~1.6 µs — ~3× too early vs `T_decrypt` (a coin-flip).

## 2. The four interventions and their results

All built into **one binary** `wireguard_trigger.ko` (clean-room from pristine 5.15
source; patch in `build/wg515-trigger/`), selected by runtime knobs so each A/B toggles a
setting on the *same loaded module*. 8 peers, ≥5–7 shuffled runs, CV < 4%.

| Intervention | Knob | Wasted polls | Throughput | Notes |
|---|---|---|---|---|
| Original "6-line" producer gate | (M1 patch) | ~0% change | flat (−0.3%) | null: `napi_schedule` ~63% no-op + wrong side |
| **Move the fix to the re-poll site** | `wg_supp=1` | 33% → **28%** | flat | fires correctly (96%) but waste regenerates (see §5) |
| **Active wait / batching (hrtimer)** | `wg_trig_k=8` | 33% → 31% | flat / −0.9% | batches polls but timer self-defeats; *worse* in spread |
| **Root fix: wake only when head ready** | `wg_headwake=1` | 33% → **20%** | flat | best waste cut, but intermittent lost-wakeup STALL |

![Wasted polls drop, throughput flat](../meetings/figures/fig_wasted_vs_debit.png)

*Left: every variant reduces wasted polls (33→28→31→20%). Right: throughput is flat
(~4.1 Gb/s) everywhere. Medians, 5 reps.*

The progression is itself the story: **the more completely you fix the EoI, the more
wasted polls you remove — and it still changes nothing downstream**, while the most
complete version (`headwake`) becomes *unsafe* (a single lost wakeup deadlocks the flow
under TCP; this is why the kernel's "wasteful" MISSED re-poll exists — the waste is the
safety).

## 3. Why nothing helps the throughput (single core)

Per-core CPU under load shows **one core pinned at 100% / 97% softirq**, every other core
≤ 22%, *regardless of which fix is on*. That core's time goes to **per-packet delivery up
the stack** (GRO → `wg_packet_consume_data_done` → `napi_gro_receive` → IP/UDP/TCP),
which scales with **packets**, not **polls** (~12 s of a 20 s core budget by the cost
model). The fixes touch the cheap poll overhead (~1 µs), not the per-packet wall — so
throughput is flat. The hrtimer trigger is additionally **self-defeating**: it runs in
softirq on the very core it is trying to relieve.

Why a single core: the NIC flow hash is **IP-only** (`rx-flow-hash udp4 = IP SA/IP DA`),
so all 8 same-IP tunnels collapse onto one RX queue. The realistic
single-heavy-tunnel / site-to-site case.

## 4. Latency — also unchanged

`ping` through the tunnel under the 8-flow load, 500 samples/condition. **Median ~1.60 ms,
p99 ~2.3 ms — identical across all four variants (±2%).** Under saturation, latency is
dominated by queueing on the busy core (~1.6 ms); the wake-policy tweaks are µs-scale
(τ = 5 µs, `C_poll` = 1 µs) and invisible against it. So neither throughput **nor** latency
depends on the wake policy in this regime.

## 5. Parallelism — the only real throughput win (and it isn't the fix)

The single-core wall is a NIC-config artifact, not WireGuard. Adding the UDP ports to the
hash (`ethtool -N enp6s0f1 rx-flow-hash udp4 sdfn`) fans the 8 tunnels (distinct source
ports) across 8 of the 40 RX queues → 8 cores. IRQ affinity was already one-per-core, so
no other tuning was needed.

![One core → eight cores](../meetings/figures/fig_spread.png)

| NIC hash | Throughput | Cores in receive |
|---|---|---|
| `sd` (IP only — the funnel) | **4.1 Gb/s** | 1 (cpu5 @ 100%) |
| `sdfn` (+ UDP ports) | **9.0 Gb/s** | 8 (~55% each) |

**×2.2 throughput, ≈ line rate, from one config command — with stock WireGuard.** This is
the genuine performance improvement of the phase; it is orthogonal to the EoI fix. The
fil rouge: parallelism is both the *cause* of the bug (parallel decrypt → out-of-order →
wasted polls) and the *cure* for throughput.

### 5b. Does the fix pay off in the spread regime (CPU-per-byte)?

With headroom (8 cores at ~55%) the fix can't add throughput (already line rate), so the
right metric is CPU efficiency. We isolated **softirq CPU** (where the poll runs) summed
across cores, 8 reps:

| cond | gbps | softirq cores-equiv | wasted% |
|---|---|---|---|
| stock | 8.99 | **2.38** | 30 |
| move | 8.99 | 2.44 (+2%) | 28 |
| batch | 8.99 | 2.58 (+8%) | 37 |
| root | 8.99 | 2.54 (+6%) | 16 |

**No fix reduces CPU; `root`/`batch` slightly *increase* softirq** (their own overhead —
barriers, the hrtimer — exceeds the cheap wasted-poll savings). Total CPU is
indistinguishable (deltas ≪ run-to-run spread). So the fix gives no efficiency benefit
even where it had the best chance.

## 6. Mechanism verification — does the re-poll fix actually fire? (yes; it just doesn't help)

To be sure the negative result isn't a broken fix, we instrumented the module with
behaviour-preserving counters (`wg_diag`, read via sysfs) and confirmed in the spread
regime:

- **`wg_supp` fires correctly: it clears a genuinely-pending MISSED in 96% of its target
  cases** (`supp_cleared` = 800,855 of 830,601 UNCRYPTED-head reschedules; an independent
  rerun: 718,546 / 744,850 = 96.5%). Sanity check: the counter is exactly 0 with the fix
  off and ~720k with it on, while the fix-independent classifier stays constant — so the
  counter is causally tied to the fix path.
- It is **not** defeated by a concurrent-core re-set (`supp_reset_race` = 906, negligible)
  nor by the recheck (re-arms 4.5%).
- **Yet aggregate wasted polls barely move**, because suppressing the MISSED re-poll just
  **parks the NAPI, and the next non-head completion wakes a *fresh* poll that is also
  wasted** (head still decrypting). The waste **regenerates as a fresh wake**; the root
  cause (out-of-order completion) is untouched. Only `headwake`, by gating *all* wakes
  until the head is ready, suppresses the regeneration too (→ 20%) — and still helps
  nothing, while risking the stall.

Of stock reschedules, **54% occur with an UNCRYPTED head, 46% with an empty (drained)
queue** — both common in parallel mode.

## 7. What this means for the project (honest)

- **Performance delivered by the EoI fix on real hardware: none.** It reduces the
  wasted-poll *count* (20–50%), but that count does not bound throughput, latency, or CPU.
- **Real throughput win: parallelism (×2.2), a NIC-config change, not the fix.**
- **The contribution is knowledge, not a speedup:** a rigorous, reproducible, multi-regime
  demonstration that a plausible kernel optimisation does not help on real 10G hardware,
  *with the precise reason* (cheap polls; per-packet delivery is the wall; the kernel's
  wasteful re-poll is the lost-wakeup safety net), plus the identification of the real
  lever. This corrects the M1-loopback hypothesis with real-hardware evidence.
- **Honest caveat / open question for future work:** we measured the spread regime at
  *line-rate saturation*, where the fix can't help by construction. A fair remaining test
  is a **non-saturated, multi-core operating point** (fixed sub-line-rate offered load,
  many peers, distinct IPs) measuring peers-per-machine / CPU-per-byte with real headroom.
  The cost model predicts no win there either (decrypt + per-packet delivery dominate),
  but it is the one regime not yet directly measured.

## 8. Reproducibility

- Module + patch: `build/wg515-trigger/` (vs pristine 5.15). Knobs (all `/sys/module/
  wireguard/parameters/`): `wg_supp`, `wg_trig_k`, `wg_trig_tau_ns`, `wg_headwake`; plus
  diagnostic counters under `wg_diag`. Build recipe in `CLOUDLAB_NEXT_STEPS.md`.
- Scripts (`scripts/cloudlab/`, run on `dut`): `measure_supp.sh`, `measure_trigger.sh`,
  `measure_headwake.sh`, `measure_cpu_trigger.sh`, `measure_all.sh` (4-way consolidated),
  `measure_latency.sh`, `measure_spread.sh` (parallelism), `measure_cpueff.sh`
  (CPU-per-byte), `measure_missed.sh` (mechanism). Throughput via `genload_json.sh` on
  `gen`; wasted polls via bpftrace; CPU via `/proc/stat`; mechanism via in-module counters.
- Data: `data/cloudlab/*.csv`. Figures: `docs/meetings/figures/`. Dated raw entries:
  `CLOUDLAB_EXPERIMENTS_LOG.md`. Supervisor summary: `docs/meetings/POINT_ALAIN_2026-06-24_FR.md`.
