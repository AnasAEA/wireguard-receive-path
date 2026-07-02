# CloudLab Experiments — Log / Findings

> **Lab notebook.** What we actually observed: numbers, surprises, decisions, dead
> ends. The recipe lives in `CLOUDLAB_EXPERIMENTS_PLAN.md`; this file is the record
> of running it. Every entry references an experiment ID from the plan (E0.x, E1,
> E2…).
>
> **Discipline:** record what happened, including failures and skipped steps. Raw
> numbers + median/spread, not conclusions dressed as data. If a result is
> uncertain, say so. Newest entries at the top of the journal.
>
> Author: Anas Ait El Hadj · Inria KrakOS (LIG)

---

## Environment of record

Fill this the moment the testbed is live (E0.1–E0.2). One block per instantiation;
if we re-instantiate on different hardware, add a new block rather than overwriting.

### Instantiation #1 — live since 2026-06-17

| Field | Value |
|-------|-------|
| Date instantiated | 2026-06-17 |
| Cluster | Wisconsin (Wisc) |
| Node type | `c220g2` |
| `dut` node ID | c220g2-011308 — `ssh anasait@c220g2-011308.wisc.cloudlab.us` |
| `gen` node ID | c220g2-011310 — `ssh anasait@c220g2-011310.wisc.cloudlab.us` |
| Lease expiry | — |
| Kernel (`uname -r`) | **5.15.0-177-generic** (Ubuntu 22.04 GA LTS, not 6.x — fine) |
| CPU (sockets / cores / threads) | 2× Xeon E5-2660 v3 — 2 sockets, 20c / **40 threads** |
| Experiment NIC (192.168.1.1) | **`enp6s0f1`** (public/control = `enp1s0f0`, 128.105.145.143) |
| NIC speed (`ethtool`) | **10000 Mb/s** ✓ |
| NIC channels (`ethtool -l`) | **40 combined** (multi-queue, 1/HT thread) ✓ |
| BTF present (`/sys/kernel/btf/vmlinux`) | ✓ present |
| bpftrace / perf / headers installed | ✓ bpftrace 0.14.0, headers 5.15.0-177-generic, linux-tools (perf) |
| Stock module version | — |
| Patched module version | — |
| `decrypt_packet` probeable directly? | **YES** — `t decrypt_packet [wireguard]` present, not inlined (no noinline build needed) |
| `wg_queue_enqueue_per_peer_rx` symbol? | **NO** — inlined (`static inline` in queueing.h). E3 must use an alternative (probe decrypt completion + derive peer from skb) |

**Probe points confirmed (stock in-tree module, 5.15.0-177):** `wg_packet_rx_poll`,
`wg_packet_decrypt_worker`, `decrypt_packet` (+ `.cold`), `wg_packet_receive`,
`wg_packet_consume_data`, `napi_gro_receive` all present. Module loads via
`sudo modprobe wireguard` (not auto-loaded until a wg iface exists).

> Note: file:line refs in the plan were from a different kernel; on 5.15 the line
> numbers shift but function names are unchanged, so probes are unaffected. Re-confirm
> exact lines when patching the 5.15 WireGuard source (E0.3). Need headers for the
> exact build: `linux-headers-5.15.0-177-generic`.

### Instantiation #2 — re-instantiated 2026-06-25

Instantiation #1 expired/was torn down; re-instantiated the `wg-recv-measure` profile.
Same hardware class, **new node IDs**, and the experiment NIC moved to a different port.

| Field | Value |
|-------|-------|
| Date instantiated | 2026-06-25 |
| `dut` node ID | c220g2-011002 — `ssh anasait@c220g2-011002.wisc.cloudlab.us` |
| `gen` node ID | c220g2-011003 — `ssh anasait@c220g2-011003.wisc.cloudlab.us` |
| Kernel | 5.15.0-177-generic (unchanged) |
| Experiment NIC | **`enp6s0f0`** (was `enp6s0f1` in #1), 10000 Mb/s, up, dut 192.168.1.1 / gen 192.168.1.2 |
| Node-to-node SSH | root only (`sudo ssh gen`); user `anasait` → publickey denied |
| DUT pub | `pROuK9O0wXZbxgLEux0BAk14YiT4pQHyyuzqYGIYSTs=` |
| Module | `wireguard_trigger.ko` rebuilt from pristine 5.15 + our 5 files, srcversion `1291A7C836BD826F02BB419` |

**Re-bootstrap (scripted in `scripts/cloudlab/bootstrap_testbed.sh`).** Fresh UBUNTU22
image = blank: had to reinstall `iperf3` + `wireguard-tools` + `linux-source-5.15.0`,
re-push scripts, rebuild the module, regenerate the dut key, recreate gen namespaces +
dut peers. Gotcha logged: `insmod wireguard_trigger.ko` fails `Unknown symbol
chacha20poly1305_decrypt / curve25519_base_arch / udp_tunnel_xmit_skb` — deps not loaded;
fix is `modprobe wireguard; rmmod wireguard; insmod ours` (keeps the dep modules). Also:
`iperf3 -s -D` daemons started in one ssh session die (SIGHUP) when that session closes —
only matters for manual smoke tests; the measure scripts start servers + drive load in the
same session, so they're fine. Result: **8/8 peers handshake**.

**Spread result reconfirmed on the fresh hardware (`measure_spread.sh 8`):**

| rx-flow-hash | Throughput | Cores >50% busy |
|---|---|---|
| `sd` (IP-only funnel) | 4.08–4.10 Gb/s | 1 (cpu9 @ 100%) |
| `sdfn` (+ L4 ports) | 8.99 Gb/s | 8 (~52–55% each) |

×2.2 holds — the headline parallelism win is not an artifact of instantiation #1.

### Meeting with Alain — 2026-06-25 (new research directions)

Day-to-day is André; this was a point with **Alain** (lead). Three directions came out of
it, to be measured with the two-sided fix:

1. **Keep the fix on BOTH sides — producer AND consumer.** Rationale (Alain): the
   consumer-side suppress (`wg_supp`) cancels a wasted re-poll, but the wake *regenerates*
   via the normal producer path (next non-head completion calls `napi_schedule`); a
   producer-side gate (the original/`wg_headwake` idea) can *intercept that regenerated
   wake too*. So the two compose — suppress the re-poll AND gate its regeneration. Action:
   make `wg_supp` and `wg_headwake` composable (today they're mutually exclusive — headwake
   returns early before the supp block) and A/B the combined mode.
2. **Throughput/latency are the wrong yardstick; measure the CPU we actually save.** Even
   with flat throughput, removing a wasted operation is a real CPU/energy saving. Focus on
   **tail latency** (which should reflect the saved softirq work) and CPU-per-op, ideally at
   a **non-saturated** operating point where the µs saving isn't drowned by queueing.
   (Caveat from our own data: `measure_cpueff` at line-rate saturation showed NO softirq-CPU
   drop — so the fair test is sub-saturation, not the saturated regime we already measured.)
3. **The cost model is hardware-specific — test sensitivity to decryption speed.** CloudLab
   Xeons decrypt fast (ChaCha20-Poly1305 with SIMD, `T_decrypt`≈5–6 µs), so the wasted poll
   fires ~3× too early and the fix is null. If decrypt were *slower* relative to poll cost,
   the head stays UNCRYPTED longer → more wasted re-polls → the fix may remove more and
   matter more. Plan: a `wg_decrypt_delay_ns` knob (busy-wait injected in the decrypt path,
   poll cost unchanged) to sweep `T_decrypt` and find the regime where the fix pays — turns
   the null result into a parametric "where does this matter" finding. Cross-check by
   forcing the generic (non-SIMD) crypto path. Don't take CloudLab's numbers at face value.

**Result — two-sided fix A/B (`measure_missed.sh 8 15`, sdfn spread, single 15 s run/cond).**
Made `wg_supp` + `wg_headwake` composable (`build/wg515-trigger/receive.c`: headwake no
longer returns early; module srcversion `EA06EE82AFA1C813458F113`) and added a `both`
condition. Wasted polls as a fraction of all polls:

| cond | knobs | wasted % | wasted count | of wasted: MISSED re-poll / fresh-wake |
|---|---|---|---|---|
| stock | — | 30.4% | 693,747 | 95.4% / 3.9% |
| move | `wg_supp=1` | 28.7% | 621,051 | 91.7% / 7.5% |
| root | `wg_headwake=1` | 17.7% | 343,410 | 98.0% / 1.3% |
| **both** | `wg_supp=1 wg_headwake=1` | **15.3%** | **283,894** | 97.9% / 1.3% |

**Confirms Alain's compose rationale.** `move` alone leaves more *fresh-wake* regeneration
(7.5% of its wasted vs 3.9% stock — the re-poll it cancels comes back as a fresh producer
wake). Adding the producer gate (`headwake`) intercepts that regeneration; `both` removes
the most overall: **30.4 → 15.3% (~50% fewer wasted polls)**, ~17% below headwake alone
(283,894 vs 343,410). The two sides are additive. Single-run per cond (~2M polls each, so
the ratio is stable); a few reps would firm the both-vs-root gap (15.3 vs 17.7). **Open:
this is the wasted-poll *count* — whether it converts to a user-visible win is what the
sub-saturation tail-latency (#2) and decrypt-cost-sweep (#3) experiments test next.**

### Instantiation #3 — re-instantiated 2026-06-26

Lease expired again. New nodes: `dut` c220g2-010630, `gen` c220g2-010628 (NIC `enp6s0f0`,
same as #2, 10G, up; DUT pub `z2HDdaydsU4sgYL5zMnL4dk3nJ8kWvyvDbDScnb35xo=`). The
`bootstrap_testbed.sh` written for #2 paid off: one command restored everything (packages,
module build srcversion `EA06EE82…`, dut key, 8 peers handshaking, 64 gen namespaces
pre-created for the peer sweep). Re-validated at 8.96 Gb/s in the sdfn spread.

**Two-sided fix peer sweep (8 → 64 pairs) — the clean result.** Data:
`data/cloudlab/twosided_peersweep_20260626.csv`, figure `docs/meetings/figures/
fig_twosided_peers.png`. Wasted polls as % of all polls:

| pairs | stock | move (supp) | root (headwake) | both |
|---|---|---|---|---|
| 8  | 27.0% | 25.8% | 15.4% | 14.8% |
| 16 | 27.3% | 26.1% | 15.9% | 13.8% |
| 32 | 26.8% | 25.1% | 15.0% | 13.1% |
| 64 | 27.5% | 25.3% | 15.4% | 14.4% |

Reads: (1) `both` ≈ halves wasted polls (~27 → ~14%) and is additive; (2) the regeneration
shows in the counters — `move` alone pushes the *fresh-wake* share of wasted from ~3% (stock)
to ~6%, and adding the producer gate drops it back to ~1%; (3) **flat from 8 to 64 pairs** —
the M1 loopback's "benefit grows with peers" does NOT reproduce on this real-HW spread regime.

**Measurement bug found + fixed.** First runs showed `polls=1` / `polls=0` for the *first*
condition (stock) and intermittently root/both. Cause: the condition was measured before the
tunnels re-handshaked/ramped after the module reload (cold start), not a real 0% or a headwake
stall. Fix: a warm-up genload burst before the condition loop in `measure_missed.sh`. After
the fix all cells capture ~1.8–2.2M polls and root/both run clean (no stall) — so the earlier
root/both zeros were the same cold-start cascade, not the lost-wakeup deadlock I'd feared.

**#2 tail latency — noisy, inconclusive.** Pulled 4 `taillat_*.csv` (8/16/32/64). `both`
beats `off` at N=16, loses at N=8, ties at N=32, with isolated 10–12 ms outliers on both
sides, and the `off` runs returned far fewer ping samples (769–795 vs 2000) — a methodology
flaw. Yesterday's "p99 1.17 vs 1.25" single-run hint does NOT survive. Needs: more samples,
a latency tunnel isolated from the load, and fixing the `off`-side sample loss before any
claim.

**#3 decrypt sweep — knob works, methodology breaks at high delay.** `wg_decrypt_delay_ns`
does lengthen `T_decrypt` and stock wasted polls rise with it (≈28% → ≈44%), with the fix
removing more — the hypothesised direction. But past ~10–20 µs/packet the busy-wait collapses
the pipeline (throughput → 0, `gbps` capture returns 0.000/NA, wasted% goes meaningless).
Needs a re-run at a capped sub-line-rate offered load so slowing decrypt doesn't implode the
flow, plus a fix to the throughput capture.

**Doc work.** Rewrote `docs/meetings/POINT_ALAIN_2026-06-24_FR.md`: corrected the framing
(the fix removes real wasted CPU work — throughput was the wrong yardstick, per Alain), made
the voice personal, and enriched it with the peer-sweep figure/table, the real two-sided code,
the cost model, and an honest "still being measured" status for #2/#3.

### Phase A result — sub-saturation latency + CPU (analyzed 2026-07-02)

Instantiation #5 (dut c220g2-011319 / gen 011315). Ran `measure_subsat.sh` (peer 0 =
sockperf latency only, peers 1..7 = capped bulk, sdfn), off vs both × loads 0/2/4/6 × 8 reps
= 64 runs, `data/cloudlab/subsat_20260701_0609.csv`. Analyzed with
`scripts/cloudlab/analyze_subsat.py` (figures `fig_subsat_cpu.png`, `fig_subsat_latency.png`).

- **Fairness clean:** off vs both actual load matches ≤3.4% (≤1.2% at 4/6) — fair comparison,
  and `both` does not throttle throughput.
- **CPU: clean null.** softirq/system/total CE indistinguishable off vs both at every load
  (deltas −4.7%…+1.6%, all p≈0.4–1.0). No CPU saving at sub-saturation on c220g2.
- **Latency: inconclusive + confounded.** both ~7–8% lower p99 at 2 and 4 Gb/s but not
  significant (p≈0.37–0.71, IQR overlap); the tail is *worst at the lowest nonzero bulk load*
  (~1.5–1.7 ms @1.1 Gb/s vs ~1.0 ms @3.1; 0-load p99 floor ~370 µs) — a CPU C-state/frequency
  artifact (schedutil), not a poll effect. So the gap is within power-state noise.

Provenance of the two partial CSVs from the same session: `subsat_20260701_0400.csv` is the
first (aborted) start — its 4-Gb/s rows carry `REJECT_load_dev` ≈0.44/0.55, the observation
that led to treating targets as nominal and verifying actual load per run;
`subsat_20260701_0605.csv` is a 3-row false start minutes before the real campaign (`_0609`).
Kept as methodology provenance, not analyzed.

**Verdict: clean c220g2 null** (matches the cost model — a ~1 µs wasted poll can't move a
ms-scale, C-state-dominated tail). Next: decrypt-cost sweep (where a win could appear on
slower crypto), an optional governor=performance latency re-test to resolve the 7% lean, and
the headwake soak. See `CLOUDLAB_PLAN_phase2.md` Phase 0 result + reprioritized steps.

---

## Cost-model summary (the headline table)

The deliverable of Phase C. Fill as E2–E5 produce numbers. Medians; note units.
Keep stock and patched side by side.

| Quantity | Source | Stock @8p | Notes |
|----------|--------|-----------|-------|
| `T_decrypt` (per packet) | E2 | **~5–6 µs** | mode [4K,8K)ns, 6.85M samples |
| `Δ_complete` (decrypt gap, per core) | E3 | **bimodal: ~5 µs (active) / ~100 µs (idle)** | active mode ≈ T_decrypt; sets the affordable trigger delay |
| `C_poll` (empty/wasted poll) | E4 | **~1.0 µs** | `@poll_avg_ns[0]`=1010 (clean, poll-only) |
| delivery setup (fixed, k≥1) | E4 | **~3.7 µs** | line intercept; the prize batching amortizes |
| `C_deliver` (per packet in poll) | E4 | **~1.64 µs** | slope k=1..16; clean run |
| `napi_gro_receive` (per pkt) | E5 | **~1 µs** (tail ~10µs) | component of C_deliver; tail = GRO flush up stack |
| `C_stack` (batch prize / poll) | E4/E5 | **~3.7 µs/poll** | = delivery-setup; per-pkt 5.3µs@batch1 → 1.9µs@batch16 |

**Derived trigger inputs (once the above are filled):**
- Break-even batch size `k*` where `(k−1)·C_stack > C_poll`: —
- Affordable wait vs `Δ_complete`: —

---

## EoI signature — wasted-poll fraction (E1)

Fraction of `wg_packet_rx_poll` returns at `work_done == 0`. Compare to M1 baseline
(loopback, ARM): −8.8 % (1 peer) … −21.9 % (8) … −20.7 % (32) wasted-poll reduction.

| Peers | Stock bucket-0 frac | Patched bucket-0 frac | Δ (this testbed) | M1 Δ (ref) |
|------:|:-------------------:|:---------------------:|:----------------:|:----------:|
| 1  | 35.8 % | 36.6 % | ~0 (noise, 1 run) | −8.8 % |
| 4  | — | — | — | −9.3 % |
| 8  | 33.0 % | 33.2 % | ~0 (noise, 1 run) | −21.9 % |
| 16 | — | — | — | −12.4 % |
| 32 | — | — | — | −20.7 % |

## GRO batch size (E5)

Mean packets per GRO flush. M1 ref: 3.1→3.3 (1p), 8.7→9.6 (8p), 7.7→8.9 (32p).

| Peers | Stock | Patched | M1 ref (stock→patched) |
|------:|:-----:|:-------:|:----------------------:|
| 1  | — | — | 3.1 → 3.3 |
| 8  | — | — | 8.7 → 9.6 |
| 32 | — | — | 7.7 → 8.9 |

---

## Journal (newest first)

### Entry template (copy for each run)

```
### YYYY-MM-DD — <ID> — <short title>
- Module(s): stock / patched   Peers: <n>   Runs: <k>   Load: <iperf3/flood, size, duration>
- Probe/command: <file or one-liner>
- Result: <medians + spread; or the histogram shape>
- Compared to expectation/M1: <matches / differs how>
- Surprises / issues:
- Decision / next:
- Raw output: <path or artifact name>
```

---

### 2026-06-24 — Mechanism VERIFIED — ★ wg_supp fires at 96% but waste regenerates as fresh wakes (in-module counters)

Question (raised before changing the fix): in the parallel (sdfn) regime, is MISSED still
the dominant wasted-poll cause, and does `wg_supp` actually fire / prevent the wasted
calls? Added behaviour-preserving in-module counters (`wg_diag`, sysfs-readable) at the
poll-completion point. Builds `C8808D9…` then `wireguard_trigger.ko` with diag.

- **MISSED still dominant in parallel:** of stock wasted polls, **95%** are MISSED re-polls
  (vs 99.7% single-core). Of reschedules: **54% UNCRYPTED-head, 46% empty-drain**
  (empty_missed=735k, uncrypt_missed=865k). So my first guess (empty case dominates and the
  fix misses it) was **REFUTED** — UNCRYPTED is the slight majority, the case the fix DOES
  handle.
- **The fix fires correctly:** `supp_cleared` = 800,855 of 830,601 catchable = **96%** of
  UNCRYPTED-head reschedules cleared. Independent rerun 718,546/744,850 = 96.5%. NOT
  defeated by concurrent re-set (`supp_reset_race`=906, negligible — that hypothesis also
  REFUTED) nor recheck re-arm (37,657 = 4.5%).
- **Sanity check (causality):** `supp_cleared` = 0 with wg_supp=0 (phases A & C), 718k with
  wg_supp=1 (phase B); meanwhile fix-independent `uncrypt_missed` ≈ 745–773k in ALL phases
  → counter is tied to the fix path; load + diag live and stable.
- **So why does aggregate wasted barely drop (30→27%)?** Suppressing the MISSED re-poll
  parks the NAPI; then the next non-head completion wakes a **fresh** poll that is ALSO
  wasted (head still decrypting). **The waste regenerates as a fresh wake** — root cause
  (out-of-order completion) untouched. `headwake` gates all wakes at the producer so it
  stops the regeneration too (→16-20%), but still helps nothing and risks the stall.
- **Method note:** the earlier `measure_missed` "92% still MISSED" used a cross-core
  NAPI-state classifier that is racy in spread mode; the in-module counters sit at the
  decision point and are authoritative. Trust the counters.
- **Counters racy (plain ++ across cores)** → reliable for ratios/orders of magnitude
  (800k vs 906 unambiguous), not exact totals.

This CLOSES the mechanism question: the re-poll fix works exactly as designed (fires 96%),
but it cannot help because the wasted polls regenerate and were never the bottleneck.

---

### 2026-06-24 — Design B — ★★ BREAKTHROUGH: spread RX across cores ⇒ 4.1 → 9.0 Gb/s (×2.2), single-core wall GONE

`measure_spread.sh 8` — stock module, flip NIC `rx-flow-hash udp4` from `sd` (IP only)
to `sdfn` (+L4 ports), measure throughput + per-core CPU each. Artifacts
`data/cloudlab/cpu_sd_spread.csv` / `cpu_sdfn_spread.csv`, fig
`docs/meetings/figures/fig_spread.png`.

```
hash    throughput   cores >50% busy
sd      4.08-4.13    1   (cpu5 = 100% / 97.6% softirq)
sdfn    8.99-8.99    8   (cpu29/7/26/27/1/28/3/9 ~50-60% each)
```

- **×2.2 throughput (4.1 → 9.0 Gb/s ≈ 10G line rate) from ONE ethtool command.** The 8
  tunnels share src/dst IP but have distinct UDP source ports; adding the ports to the
  hash fans them across 8 of the 40 RX queues → 8 cores. IRQ affinity was already one-per-
  core (irq144→cpu5 etc.), so no extra tuning needed. **The single-core wall was the NIC
  hash config, NOT WireGuard.**
- **Now the cores have HEADROOM (~55%)** — this is the regime where the EoI fix can finally
  matter: reclaimed wasted-poll cycles no longer convert to throughput (already near line
  rate) but to **lower CPU% → more peers per box**. Note softirq is now a big share per
  core (e.g. cpu29 38.5%), so per-core poll efficiency is back in play.
- **Reverted hash to `sd` (default) after the run.** To enable: `sudo ethtool -N enp6s0f1
  rx-flow-hash udp4 sdfn`.
- **Connects to the bug's theme:** parallelism is both the *cause* of the EoI (parallel
  decrypt → out-of-order → wasted polls) and the *cure* for throughput (spread RX).
- **NEXT (the right experiment):** in `sdfn` mode, re-run the stock/move/batch/root A/B but
  measure **CPU-per-byte at fixed ~9 Gb/s** (not throughput). If a fix lowers per-core CPU
  at equal throughput, that is its real value. `measure_all.sh`-style but with the spread
  hash + CPU sampling.

---

### 2026-06-24 — Latency under load — ★ identical across all 4 variants (~1.6 ms) ⇒ saturated core dominates latency too

`measure_latency.sh 8 14` — ping through the tunnel (ns_c0 → 10.0.0.1) while the 8 flows
saturate the core, 500 samples/condition. Artifact `data/cloudlab/lat_20260624.csv`, fig
`docs/meetings/figures/fig_latence.png`.

```
cond        median   p90     p99
stock       1.60 ms  2.06    2.34
move        1.57 ms  2.01    2.33
batch       1.62 ms  2.03    2.32
root        1.60 ms  2.03    2.39
```

- **Latency is identical across all variants (~1.6 ms median, ~2.3 ms p99, ±2%).** Under
  saturation it is dominated by queueing on the bottleneck core (~1.6 ms); the wake-policy
  knobs are µs-scale (τ=5µs, C_poll=1µs) → invisible against 1.6 ms. Even the trigger's τ
  (which I expected to hurt tail latency) doesn't show — it's ~300× smaller than the queue.
- **Closes the latency avenue for THIS regime:** neither throughput NOR latency depends on
  the wake policy when one core saturates — both are governed by per-packet delivery on
  that core. The τ-latency cost would only appear at *light* load (short queue); not the
  operating point here. Only remaining lever for either metric: spread RX across cores
  (Design B). idle RTT (no load) was ~0.6 ms for reference.

---

### 2026-06-24 — Consolidated A/B + figures (for the supervisor point écrit)

`measure_all.sh 8 5` — one binary, 4 conditions back-to-back, shuffled, 5 reps, same load
+ a per-core CPU snapshot. The canonical dataset for the report. Artifacts:
`data/cloudlab/all_20260624.csv`, `cpu_20260624.txt`; figures
`docs/meetings/figures/fig_wasted_vs_debit.png`, `fig_cpu_coeurs.png`
(via `scripts/cloudlab/plot_results.py`).

```
condition   wasted%  débit(Gb/s)   (medians, 5 reps, CV<4%)
stock        32.9      4.15
move(supp)   27.7      4.15
batch(k=8)   31.7      4.10
root(head)   20.0      4.13     (clean this run — no stalls in 5/5)
CPU: cpu5 = 100% busy / 96.9% softirq, all others <=22%
```

The one-glance story: wasted polls drop (33→28→32→20%) while throughput stays flat
(~4.1) — and one core is saturated. Written up for Alain in
`docs/meetings/POINT_ALAIN_2026-06-24_FR.md` (narrative + both figures + data table +
commands + the two code hunks). Note: `root` ran stall-free across all 5 reps here, but
the intermittent-stall caveat from the 2026-06-24 Phase E2 entry stands (it is a real
lost-wakeup hazard, just not hit this run).

---

### 2026-06-24 — Phase E2 — ★ ROOT FIX (head-gated wake, `wg_headwake`): cuts wasted polls the MOST (33%→20%) but throughput FLAT and it intermittently STALLS

Built the theoretically-correct fix: wake the RX poll ONLY when a decrypt completion makes
the head deliverable. The poll publishes the head it parks on (`peer->rx_blocked_on`,
NULL = empty ⇒ any arrival); producers wake the NAPI only when completing that exact skb
(pointer compare, never deref). Knob `wg_headwake` on `wireguard_trigger.ko` (srcversion
`EF01A40…`). Code: producer gate `build/wg515-trigger/queueing.h:228`, poll publish+recheck
`build/wg515-trigger/receive.c:522`, field in `peer.h`. Timer-free.

- **Result (3 clean reps agree — measure_headwake.sh):** hw0 (stock) wfrac ≈ 0.333, GBPS
  ≈ 4.15; **hw1 (head-gated) wfrac ≈ 0.20, GBPS ≈ 4.13.** Wasted polls 33%→20% — the
  **largest cut of any lever** (raw count ~halved: 360k→180k/run; vs wg_supp 28%, trigger
  31%). **Throughput still flat (+0.3%).** Definitive: even waking ONLY on a ready head
  does not move throughput → per-packet delivery is the wall, confirmed a 4th way.
- **Concurrency:** needs Dekker double-barriers (worker `smp_mb` between set-CRYPTED and
  reading rx_blocked_on; poll `smp_mb` between publishing and re-reading head state). The
  first build (release/acquire only) stalled at tunnel setup; barriers fixed setup. The
  fix is real — release/acquire alone is insufficient for the two-sided store-buffer race.
- **★ Intermittent STALL (the important finding):** under sustained TCP load, `wg_headwake=1`
  occasionally strands the flow (1 of 7 long runs showed GBPS≈0 though dut still did 1.09M
  useful polls = partial stall, not a dead node; one run briefly made the mgmt SSH
  unresponsive; node never oopsed/locked, recovered to load 0.01). `wg_headwake=0` never
  does this. **Why it's fundamental, not sloppy:** moving the wake to the producer means a
  single lost wakeup DEADLOCKS the flow — under TCP the stalled receiver stops ACKing →
  sender stops → no new packet arrives to self-heal. So head-gating demands PERFECT
  lost-wakeup avoidance, which is hard. **This explains WHY the kernel's "wasteful"
  MISSED/re-poll design exists: the re-poll is the belt-and-suspenders that guarantees no
  lost wakeup. The waste IS the safety.** You can trade it for efficiency but take on a
  deadlock hazard — and here you get ZERO throughput for the risk.
- **Decision:** headwake is NOT shipped as a robust fix (intermittent stall). It stands as
  the experiment proving (a) wasted polls are maximally reducible at the root yet (b)
  throughput is unmoved, and (c) the efficiency/correctness tradeoff behind the kernel's
  design. A production-safe version would need a liveness backstop (periodic/timer wake) —
  which reintroduces the very overhead the trigger showed is self-defeating here.

---

### 2026-06-23 — Phase E DIAGNOSTIC RESULT — ★ hot core stays 100% busy at k=8 ⇒ batching frees NOTHING; receive wall is per-packet softirq, not polls

`measure_cpu_trigger.sh 8 "0 8"` — per-core busy%/softirq% under 22s load, k0 vs k8.

```
k=0:  cpu5 busy=100.0% softirq=96.5%  (every other core <=20.4%, ~0% softirq)   GBPS=4.179
k=8:  cpu5 busy=100.0% softirq=97.0%  (every other core <=21.0%, ~1% softirq)   GBPS=4.141
```

- **The hot core is pinned at 100% / ~97% softirq at BOTH settings**, despite k=8 doing
  −22% useful polls. Batching freed **zero** measurable CPU on the bottleneck core →
  **outcome #1**: poll reduction is moot for throughput here. The other cores (~18–21%,
  ~0% softirq) are padata decrypt + iperf servers — not the bottleneck.
- **What cpu5's 97% softirq is actually spent on:** `wg_packet_rx_poll` → GRO +
  `wg_packet_consume_data_done` → `napi_gro_receive` → IP/UDP/TCP stack, i.e. **per-packet
  delivery up the stack**, which scales with *packets* not *polls*. Envelope: ~7.25M
  pkts × ~1.64µs ≈ 12s of the 20s budget is delivery; that is the wall.
- **Where the batching CPU saving went (hypothesis):** k=8 cut ~1.5s of poll-setup
  (1.85M→1.44M useful × 3.7µs) yet busy% didn't drop and throughput didn't rise — the
  `hrtimer` machinery (arm+cancel ~per batch, firing REL_SOFT on the SAME cpu5) plausibly
  consumed ~the same ~1.5s. **The coalescing timer is self-defeating on a saturated core:
  it runs on the very core it is trying to relieve.** Confirm with a timer-free K-only
  test (set `wg_trig_tau_ns=0` ⇒ pure count, no timer): if throughput then rises, the
  timer was the culprit; if cpu5 stays 100% / flat, per-packet delivery is the hard wall.
- **Settled conclusion (3 measurements agree — wg_supp, wg_trig, per-core CPU):** under
  single-core RSS funneling, the WireGuard receive path is **bound by per-packet delivery
  softirq on one core**. The EoI wasted-poll inefficiency is real and suppressible but is
  **not** the throughput bottleneck, and hrtimer coalescing cannot help because it loads
  the saturated core. **Throughput-on-Design-A is the wrong metric for this fix.**
- **Decision / fork:**
  (a) cheap decider — timer-free K test (`wg_trig_tau_ns=0`) to nail timer-vs-wall;
  (b) **Design B** — spread RX across cores (`ethtool -N enp6s0f1 rx-flow-hash udp4 sdfn`)
      so no single core saturates; then the metric is **CPU-per-byte / peers-per-box**,
      where reclaimed poll cycles can actually count;
  (c) **latency** — measure how `wg_supp`/trigger shift delivery timing (note: τ likely
      *hurts* latency under saturation; `wg_supp` is the timer-free, latency-friendly one).

---

### 2026-06-23 — Phase E RESULT — ★ trigger BATCHES (−22% useful polls) but throughput FLAT-to-DOWN ⇒ receive is per-packet-delivery bound, not poll bound

`measure_trigger.sh 8 "0 8" 7` — wg_trig_k 0 vs 8, τ=5µs, same binary `4BD8E49…`, 7
shuffled runs. Artifact `~/trigger_20260623_0735.csv`.

```
k          n  gbps_med gbps_cv%  wfrac_med wfrac_cv%
k0         7     4.199      0.2     0.3288       0.3
k8         7     4.163      0.3     0.3057       3.2
k8 - k0:  dGbps=-0.036 (-0.9%)   dWastedFrac=-0.0231
```

Raw poll counts (the real story): k0 ≈ 1.85M useful + 910k wasted = 2.76M polls; k8 ≈
1.44M useful + 640k wasted = 2.08M. **Useful polls −22%, total −25%** — the trigger
batched exactly as designed (fewer polls deliver the same throughput ⇒ bigger batches).

- **But throughput did not rise — it dipped 0.9%.** Back-of-envelope: batching saved
  ~1.5s of per-poll setup (1.85M→1.44M useful × 3.7µs) over 20s ⇒ "should" be ~+9%
  throughput. It didn't appear, and we lost a hair. So the saved cycles were NOT the
  binding constraint, and/or the **hrtimer overhead** (REL_SOFT timer firing in softirq on
  the SAME saturated core, armed ~hundreds of k times) + the τ=5µs added latency cancelled
  the benefit.
- **Unified conclusion across BOTH levers** (wg_supp −25% wasted → flat; wg_trig −22%
  useful → flat-to-down): **reducing poll count does not raise throughput on a single
  saturated core.** Receive throughput here is bound by **per-packet delivery** (C_deliver
  1.64µs/pkt + GRO/stack, which scales with packets, not polls) — back-of-envelope ~12s of
  the 20s core budget — NOT by per-poll setup or wasted polls. The EoI wasted-poll cost is
  real and suppressible but is a **second-order overhead**, not the throughput bottleneck.
- **Why the trigger is slightly worse than wg_supp at cutting waste** (30.6% vs 28.1%):
  K=8 fires on the ready count and the τ timer fires regardless, so it still wakes into
  some uncrypted heads; wg_supp's pure head-gated park is cleaner. And the trigger adds
  timer cost wg_supp doesn't.
- **Decision — this reframes the project (honestly):** throughput-on-Design-A is NOT the
  metric that shows the fix's value, because poll overhead isn't throughput-binding when
  one core saturates on per-packet delivery. The value, if any, lives in **(a) latency**
  (wasted polls / batching change *when* packets are delivered, not how many) and **(b) the
  multi-core / headroom regime** (Design B: spread RX across cores so freed poll cycles
  become capacity/peers-per-box rather than being delivery-capped). Next: **diagnostic** —
  per-core busy%/softirq% at k0 vs k8 to see whether batching actually freed the hot core
  or the timer ate it (`measure_cpu_trigger.sh`); then decide latency-metric vs Design B.
- **Caveat:** load is iperf3 (TCP); τ-added latency could nick TCP throughput
  independently. A UDP-load cross-check would isolate that, but the per-core CPU read is
  the more decisive next step.

---

### 2026-06-23 — Phase E0 RESULT — ★ suppression WORKS (−5.2pp wasted) but throughput FLAT ⇒ wasted polls were cheap

`measure_supp.sh 8 7` — wg_supp 0 vs 1, coalescer off (wg_trig_k=0), 7 shuffled runs,
same binary `4BD8E49…`. Artifact `~/supp_20260623_0720.csv`.

```
mode       n  gbps_med gbps_cv%  wfrac_med wfrac_cv%
supp0      7     4.202      0.5     0.3333       1.9
supp1      7     4.203      0.2     0.2813       1.5
supp1 - supp0:  dGbps=+0.001 (+0.0%)   dWastedFrac=-0.0520
```

Two clean facts (CV<2%, so both solid):

- **The fix works and is safe.** Wasted fraction 33.3% → 28.1% (−5.2pp, −15.6% rel). In
  raw counts ~937k → ~703k wasted polls/run = **~234k fewer wasted polls (−25%)**; useful
  polls also dropped ~79k (slightly bigger batches). **No stall** — GBPS held at 4.2, not
  0, so the lost-wakeup corner case did NOT bite under continuous load. The consumer-side
  MISSED suppression does exactly what it was designed to, unlike the null producer-side
  first fix. **Mechanism confirmed.**
- **Throughput did not move (+0.0%).** Wasted polls are cheap (`C_poll`≈1µs): removing
  234k frees ~0.23s over 20s ≈ 1% of the bottleneck core; with the bigger useful batches
  maybe ~2–3% total. On a core whose time is dominated by **delivery** (3.7µs setup +
  1.64µs/pkt in the *useful* polls, unchanged here), that doesn't add delivery capacity.

- **Interpretation:** the wasted re-poll is **suppressible but was never the throughput
  bound**. The binding constraint is the per-packet delivery work in the useful polls (and
  the in-order delivery/decrypt serialization behind it), not the wasted-poll count. This
  is the "wasted polls were nearly free" outcome — now measured, not hypothesized. It also
  explains residual 28% wasted: a non-head completion that wakes a fresh poll *before* the
  head crypts is still wasted; suppression only kills the MISSED *cascade* after it, not
  the first wake (producer can't know head state without a race or a delay).
- **Decision / next:** keep `wg_supp` as the clean isolated proof that the MISSED re-poll
  is suppressible (good report result on its own). For **throughput**, the lever is
  batching the *useful* polls to amortize the 3.7µs setup (per-pkt 5.3µs@k1 → 1.9µs@k16) —
  i.e. the count-or-timeout trigger `wg_trig_k` (Phase E). Run `measure_trigger.sh 8 "0 8"
  7` next. Optionally stack `wg_supp=1` with `wg_trig_k=8` later to see if suppression +
  batching beats batching alone.

---

### 2026-06-23 — Phase E0 — ★ simplest fix BUILT: consumer-side MISSED re-poll suppression (`wg_supp`)

The original-fix idea, moved to the place the trace says it belongs. Added one knob
`wg_supp` (module param) to `wireguard_trigger.ko` (srcversion now `4BD8E49…`).

- **What it does:** in `wg_packet_rx_poll`, on the completion path (`work_done < budget`,
  i.e. the loop stopped on an empty or UNCRYPTED head), if the head is UNCRYPTED it
  `clear_bit(NAPI_STATE_MISSED)` before `napi_complete_done` so the kernel **parks the
  NAPI instead of re-polling**. A non-head decrypt completion that set MISSED would
  otherwise force an immediate re-poll re-finding the same UNCRYPTED head — the wasted
  no-op that is 99.7% of all wasted polls (Phase D). The head's *own* completion later
  `napi_schedule`s a fresh, productive poll. Re-checks the head after clearing
  (`smp_mb__after_atomic`) to re-arm MISSED if a wake raced in.
- **Why this differs from the null first fix:** that gated `napi_schedule` (producer
  side) — null because the bell is ~63% already-ringing and producer-side can't see what
  the poll consumes. This acts at the **consumer/poll completion**, where the head state
  is read authoritatively (single consumer ⇒ race-free wrt the queue), and cancels only
  the re-poll it can *see* will be wasted, keeping the 44% productive reschedules.
- **Honest caveat (lost-wakeup):** narrow race — head becomes CRYPTED + MISSED set in the
  gap between our clear and `napi_complete_done`'s cmpxchg. Self-heals under continuous
  load (next packet re-wakes); only a true stall if traffic idles in that window. The
  recheck closes most of it; a small hrtimer backstop would make it bulletproof for idle.
  First experiment runs under continuous iperf, so test now, add backstop only if a stall
  shows.
- **Layering note:** poking `NAPI_STATE_MISSED` from a driver is a deliberate prototype
  hack; a production form would propose a `napi_complete`-with-condition API.

**Exact change** (vs pristine 5.15 `drivers/net/wireguard/`). Stock was two lines at the
end of `wg_packet_rx_poll`:

```c
/* receive.c (stock) — wg_packet_rx_poll completion */
	if (work_done < budget)
		napi_complete_done(napi, work_done);
```

Patched to (`build/wg515-trigger/receive.c:514-544`):

```c
	if (work_done < budget) {
		/* MISSED re-poll suppression (wg_supp): the loop stopped on an empty or
		 * UNCRYPTED head. If the head is UNCRYPTED, a MISSED set by a non-head
		 * decrypt completion would force a re-poll re-finding it -> wasted no-op
		 * (Phase D: 99.7% of wasted polls). Clear MISSED to park the NAPI; the
		 * head's own completion re-wakes a productive poll. Single consumer, so
		 * reading the head here is race-free; re-check after clearing to not drop
		 * a wake that raced in. */
		if (wg_supp) {
			struct sk_buff *head = wg_prev_queue_peek(&peer->rx_queue);

			if (head &&
			    atomic_read_acquire(&PACKET_CB(head)->state) ==
				    PACKET_STATE_UNCRYPTED) {
				clear_bit(NAPI_STATE_MISSED, &napi->state);
				smp_mb__after_atomic();
				head = wg_prev_queue_peek(&peer->rx_queue);
				if (head &&
				    atomic_read_acquire(&PACKET_CB(head)->state) !=
					    PACKET_STATE_UNCRYPTED)
					set_bit(NAPI_STATE_MISSED, &napi->state);
			}
		}
		napi_complete_done(napi, work_done);
	}
```

Plus the knob — `build/wg515-trigger/main.c:35-37`:

```c
unsigned long wg_supp;               /* 0 = off (default, stock) */
module_param(wg_supp, ulong, 0644);
MODULE_PARM_DESC(wg_supp, "Suppress wasted MISSED re-polls when head is UNCRYPTED (0=off)");
```

and its declaration `build/wg515-trigger/queueing.h:201`:
`extern unsigned long wg_supp;`. No other files change for this fix (the `peer.h`/`peer.c`/
`queueing.h`-enqueue edits belong to the separate `wg_trig_k` coalescer).

- **Smoke test PASSED:** builds clean, all three knobs present (`wg_supp`, `wg_trig_k`,
  `wg_trig_tau_ns`), loads, `wg_supp` 0→1 live, wg0 create/teardown + `rmmod` clean.
- **Next:** `measure_supp.sh 8 7` — wg_supp 0 vs 1, coalescer off. Hypothesis: wasted_frac
  drops below 33%, GBPS rises. This is the simplest thing that could move the headline;
  the count-or-timeout trigger (`wg_trig_k`) is the fuller version if this leaves headroom.

---

### 2026-06-23 — Phase E — ★ trigger module BUILT (`wireguard_trigger.ko`), single-binary runtime knob

Implemented `TRIGGER_DESIGN.md` as the count-or-timeout RX coalescer and built it.

- **Single binary, runtime knob.** Module param `wg_trig_k` (0644): `0` ⇒ byte-identical
  stock behaviour, `≥1` ⇒ trigger on; `wg_trig_tau_ns` (default 5000) is the coalesce
  window. So the A/B is `k=0` vs `k=8` on the *same loaded module* — no base divergence,
  no reload variance, the strongest possible comparison. Toggle via
  `/sys/module/wireguard/parameters/wg_trig_k`.
- **The change (5 files, vs pristine 5.15):** `peer.h` +`struct hrtimer
  rx_coalesce_timer; atomic_t rx_timer_armed, rx_ready;`. `peer.c` hrtimer_init
  (`CLOCK_MONOTONIC, REL_SOFT`) in create, `hrtimer_cancel` in `peer_remove_after_dead`
  after the crypt_wq flushes (no decrypt worker can re-arm past there). `queueing.h`
  rewrites `wg_queue_enqueue_per_peer_rx`: on CRYPTED completion `atomic_inc_return(rx_ready)`
  — ≥K ⇒ cancel timer + `napi_schedule`; else `atomic_cmpxchg`-arm one timer (τ). DEAD/
  error and k=0 keep the bare immediate wake. `receive.c` adds the timer callback
  (`napi_schedule`, NORESTART) + resets `rx_ready` on poll entry. `main.c` defines the params.
- **Design deviation (deliberate, safe):** readiness is the **counter** `rx_ready`, NOT a
  `wg_prev_queue_peek` of the head. The peek is single-consumer (the poll); calling it
  from the multi-core decrypt workers / timer would race the `peeked` pointer. Counter is
  a safe proxy and is exactly the `ready` estimate the design's K fast-path already needs.
  Timer is single-shot ⇒ τ is also the liveness bound (τ_max ≡ τ); the head-ready re-arm
  variant is dropped for the same race reason.
- **Build = clean-room.** dut's `~/linux-source-5.15.0` is contaminated (stale
  `wg_trace`/`wg_dbg` in receive.c/main.c, no .orig backups) AND the repo's `linux-source/`
  is a *newer* revision (uses `skb->headers`, `cpumask_nth`) that won't compile on 5.15.
  So extracted a PRISTINE tree from `/usr/src/linux-source-5.15.0/...tar.bz2`, dropped the
  5 modified files in, built against `5.15.0-177` headers. Patch kept in repo at
  `build/wg515-trigger/`. srcversion `3076ED3…`.
- **Smoke test PASSED:** compiles clean (only the pre-existing allowedips frame-size
  warnings); loads with k=0; both params present + live-tunable (set k=8 OK);
  `ip link add/del wg0` exercises hrtimer init + the teardown `hrtimer_cancel` with a
  clean `rmmod` (an oops would have blocked unload).
- **Next:** `measure_trigger.sh 8 "0 8" 7` — the k=0 vs k=8 A/B. Hypothesis: wasted_frac
  drops, batch grows, and on the CPU-bound core GBPS rises — the headline the 6-line fix
  never moved.

---

### 2026-06-22 — Low-variance sweep @8 peers — ★ M1 6-line fix confirmed NULL with tight error bars

`run_sweep.sh "8" "stock patched" 7` — 14 runs, module order shuffled per round,
auto-elevating scripts. Each run: insmod + 8 peers + iperf servers + gen load +
bpftrace wasted/useful poll counts. Artifact: `~/sweep_20260622_0826.csv`.

```
mod      peers   n  gbps_med gbps_cv%  wfrac_med wfrac_cv%
patched      8   7     4.155      0.3     0.3349       1.7
stock        8   7     4.169      0.2     0.3306       1.4

median(patched) − median(stock):  dGbps=-0.014  dWastedFrac=+0.0043
```

- **CV is tiny everywhere (0.2–1.7%, all ≪ 5%)** ⇒ 7 runs/module is more than enough;
  the small-run worry is closed. These medians are solid.
- **The patched−stock deltas are noise, and the sign is even slightly *wrong*:**
  throughput −0.014 Gb/s (−0.3%, within CV), wasted fraction **+0.0043** (patched wastes
  *more*, not less). The M1 6-line `napi_schedule` gate does **nothing measurable** on a
  real 10 G NIC under saturation. This is the null we predicted, now with error bars
  instead of a single run.
- Wasted-poll fraction sits at **~33%** both modules — a third of `wg_packet_rx_poll`
  invocations still find the head un-decrypted. That is the headroom a real trigger must
  reclaim; the M1 gate leaves it entirely on the table.
- **Decision / next:** baselines are locked. Proceed to Phase E — implement
  `wireguard_trigger.ko` (hrtimer + atomic in `wg_peer`, τ≈5 µs / K≈8 count-or-timeout
  gate, per `TRIGGER_DESIGN.md`) and re-run this exact sweep as `"stock patched trigger"`
  to measure the delta the gate failed to deliver.

---

### 2026-06-22 — Saturation CONFIRMED — ★ one core at 100% softirq @4.2 Gb/s ⇒ CPU-bound, Design A locked

`measure_sat.sh stock 8` (self-contained: insmod + peers + iperf servers + gen load +
per-core busy% sample + throughput). 22 s window under live 8-peer load:

- **CPU5 = 100.0% busy, 97.5% softirq**; every other core ≤ 23%. **GBPS = 4.200.**
- → the receive path is **bottlenecked on a single core saturated in NET_RX softirq** —
  that is where `wg_packet_rx_poll` (GRO + delivery + the wasted polls) runs. **Wasted
  polls burn the bottleneck core's cycles.** The ~20% cores are decrypt (padata-spread)
  + iperf servers → decrypt is NOT the ceiling; the single-core poll/GRO/delivery is.
- Hot core is CPU5 here vs CPU3 in the `/proc/softirqs` checks — the queue-2 IRQ lands on
  a different core across module reloads, but always exactly ONE core. Same phenomenon.
- **DECISION — Design A locked:** keep the single-core CPU-bound regime as the primary
  experiment. Zero headroom ⇒ any CPU the trigger reclaims converts directly to Gb/s;
  throughput is now the clean headline metric (the one the M1 fix never moved). Do NOT
  spread RX to 10G (Design B) — that's a later "it generalizes" run.
- Next: low-variance sweep (`run_sweep.sh "1 8 16 32" "stock patched" 7`) for baselines
  with error bars, then implement `wireguard_trigger.ko`.
- Scripts now live on dut `~/` (pushed via scp): `measure_sat.sh`, `measure_run.sh`,
  `run_sweep.sh`, `analyze_sweep.py`, `measure_repoll_gap.sh`, + the existing set.

### 2026-06-22 — Saturation diagnosis — ★ receive softirq funneled to ONE core (the 4 Gb/s cause)

Why ~4 Gb/s on a 10G NIC, and is the bottleneck core CPU-bound? `/proc/softirqs` NET_RX
delta over 3 s (install-free; `mpstat` absent, sysstat not installed):

- **CPU3 = 84.9% of all NET_RX**; every other CPU ≤ 1.8% (CPU20 1.8, CPU5/7/24 1.2…).
  → the receive softirq is **funneled to a single core**. Confirms the suspicion: all 8
  tunnels share dst port 51820 + gen's src IP, only the src UDP port varies, so an
  IP-only RX flow-hash collapses them onto one queue/core. **Adding peers ≠ adding cores
  → that is the 4 Gb/s ceiling.**
- **ROOT CAUSE PROVEN (re-run under load):** CPU3 70.8% NET_RX, AND `ethtool -S enp6s0f1`
  → `rx_queue_2 = 97,791,799` pkts vs every other queue 1–55 (one queue gets everything),
  AND `ethtool -n enp6s0f1 rx-flow-hash udp4` = **`IP SA` + `IP DA` only — no L4 ports.**
  So all tunnels (same src/dst IP) hash identically → queue 2 → CPU3. Definitive.
  Spread fix (Design B, later): `sudo ethtool -N enp6s0f1 rx-flow-hash udp4 sdfn` + IRQ/RPS.
- Caveat: absolute delta low (+287/3 s) → load likely idle during that exact snapshot;
  the *distribution* is the signal, re-confirm under live load + per-core busy% (next).
- **Decision (recorded):** embrace the single-core bottleneck as the experiment — do NOT
  chase 10G. The funneled regime is where the trigger pays off: wasted polls burn the
  *bottleneck* core's cycles, so reclaiming them = throughput. More peers add
  parallel-decrypt disorder on the same core (the wasted-poll condition), not cores.
  Design B (spread RX to 10G via `ethtool -N … rx-flow-hash udp4 sdfn` + IRQ/RPS) is a
  later "it generalizes" run, not the contribution. Next: confirm CPU3 ~100% busy under
  live load, then low-variance sweep (`run_sweep.sh`), then implement the trigger.

**Commands (reproduce):**
```bash
# (1) which CPUs take NET_RX softirq, how concentrated (install-free; mpstat absent)
python3 - <<'PY'
import time
def snap():
    for l in open('/proc/softirqs'):
        if l.strip().startswith('NET_RX:'): return list(map(int, l.split()[1:]))
a=snap(); time.sleep(3); b=snap()
d=sorted(((i,b[i]-a[i]) for i in range(len(a))), key=lambda x:-x[1]); t=sum(v for _,v in d) or 1
for i,v in d[:12]: print(f"CPU{i:<3} NET_RX +{v:<10} {100*v/t:5.1f}%")
PY
# -> CPU3 70.8-84.9%

# (2) per-RX-queue packet spread: is it one queue or many?
ethtool -S enp6s0f1 | grep -E 'rx.*packets' | awk '$2+0>0' | sort -t_ -k3 -n | tail -20
# -> rx_queue_2 = 97,791,799 ; all others 1-55  (one queue gets everything)

# (3) the root cause: NIC UDP hash uses no L4 ports
ethtool -n enp6s0f1 rx-flow-hash udp4
# -> "IP SA / IP DA" only -> all same-IP tunnels collide on one queue

# (4) is that bottleneck core actually SATURATED at 4 Gb/s? (busy% + softirq% under live load)
# node-to-node ssh works only as ROOT -> use `sudo ssh` (plain `ssh gen` => publickey denied,
# load never runs, busy% reads 0% everywhere). genload_json.sh must exist on gen first:
#   sudo ssh gen 'cat > /tmp/genload_json.sh' < scripts/cloudlab/genload_json.sh
sudo ssh -o StrictHostKeyChecking=no gen "bash /tmp/genload_json.sh 8 30 4" &
python3 - <<'PY'
import time
def snap():
    c={}
    for l in open('/proc/stat'):
        if l.startswith('cpu') and l[3:4].isdigit():
            p=l.split(); t=sum(map(int,p[1:])); idle=int(p[4])+int(p[5]); soft=int(p[7])
            c[p[0]]=(t,idle,soft)
    return c
a=snap(); time.sleep(10); b=snap()
rows=[]
for k in a:
    dt=b[k][0]-a[k][0]
    if dt>0: rows.append((k,100*(1-(b[k][1]-a[k][1])/dt),100*(b[k][2]-a[k][2])/dt))
rows.sort(key=lambda x:-x[1])
for k,busy,soft in rows[:12]: print(f"{k:6} busy={busy:5.1f}%  softirq={soft:5.1f}%")
PY
wait   # prints aggregate "GBPS <n>"

# Design B spread fix (later): add L4 ports to the hash, then spread IRQs/RPS
sudo ethtool -N enp6s0f1 rx-flow-hash udp4 sdfn
```

### 2026-06-22 — Phase D+ — RE-POLL GAP measured — ★ corrects the "sub-µs" claim, calibrates τ

`measure_repoll_gap.sh stock 8` (gap-only, no decrypt probe). Gap = `entry(poll N+1) −
return(poll N)` keyed by napi ptr; split by re-poll outcome, gated on prev poll having
rescheduled via MISSED (`napi_complete_done`==0).

- **Gap is ~1–2 µs, NOT sub-µs.** `@gap_all_ns` mode [1K,2K)=1.26M; mass in [1K,4K).
  `@missed_repoll_WASTED_ns` median ≈ **1.6 µs** (mode [1K,2K)=595k, then [2K,4K)=113k).
  So vs `T_decrypt≈5µs` the re-poll is **~3× too early** — the design doc's "sub-µs,
  nothing can change" was an **overstatement** (corrected in `MISSED_REPOLL_PROOF.md`).
- **Not "almost always wasted" — it's a coin flip that improves with the gap.** WASTED
  and useful gap distributions are nearly superimposed at the mode. Useful-fraction by
  bucket: <1µs 40% · **1–2µs 49%** · 2–4µs **67%** · 4–8µs 65% · 8–16µs 72%. Totals
  ≈727k wasted / ≈822k useful (53% useful; ≈ trace build's 44%).
- **τ calibration (the payoff):** useful% knee at ~2–4 µs, plateau ~72% by 8–16 µs ⇒
  the right coalesce window is **τ ≈ 4–5 µs (≈ one T_decrypt)**, NOT the guessed 20 µs.
  Updated `TRIGGER_DESIGN.md` defaults accordingly.
- **Mechanism (refined):** at poll-end the head's decrypt has a *remaining* time spread
  over ~[0,5µs]; the re-poll fires at ~1.6µs and catches ~half. Coalescing the wake to
  ~one T_decrypt lets the head (and followers) finish → bigger batches, fewer wasted
  polls. The lever is *when* the re-poll runs, exactly as designed.
- Caveat: large natural gaps are confounded with light-load idle (head more likely
  already done) → the useful% curve overstates the pure causal effect of waiting; the
  clean number is the trigger A/B sweep (Phase E). Single run, N=8. Sanity: WASTED
  count ≈727k ≈ trace build `wasted_after_resched` 898k (same order; different run/load).
- Raw: histograms in session; `RESULT repoll_gap module=stock src=81233F6… N=8`.

### 2026-06-18 — E1 A/B at 1 peer — NO clear effect at 1 peer (expected), needs multi-peer + repeats

- Same protocol both modules: 1 peer, `iperf3 -t15 -P8`, 20s `wg_packet_rx_poll` probe.
- **Wasted-poll fraction (normalized, the trustworthy metric):**
  - stock:   `@zero/@polls = 326,036 / 911,568 = 35.8 %`
  - patched: `@zero/@polls = 306,382 / 837,278 = 36.6 %`
  - → **flat / within noise. No improvement at 1 peer.**
- Raw counts NOT directly comparable (different total traffic per run): stock 911k
  polls vs patched 837k. zero −6.0%, nonzero −9.3% — but this is run-to-run drift,
  not a clean signal.
- Mildly encouraging, not conclusive: patched has more big batches (`≥16`: 18.5% vs
  15.4%) and fewer total polls at ~same throughput (4.01 vs 4.07 Gbit/s).
- Throughput unchanged, still ~4 Gbit/s single-core-bound (1 peer = 1 napi = 1 core).
- **Interpretation:** consistent with M1 (1 peer = weakest case, −8.8%). The fix
  works (module loads, traffic flows, no breakage), but the payoff needs the
  parallel-decrypt disorder that comes with MANY peers. **Decisive test = E0.5
  multi-peer + ≥5 repeats with a normalized metric.** Do NOT draw conclusions from
  this single 1-peer run.

### 2026-06-19 — Phase D confirm — trace build (is the wasted poll a MISSED re-poll?)

Before designing, confirm the mechanism. `wireguard_trace.ko` = **stock** (restored
`queueing.h.orig`) + 4 counters in `wg_packet_rx_poll`: `polls`, `wasted`
(work_done==0), `resched` (napi_complete_done returned false = MISSED forced a
reschedule), `wasted_after_resched` (wasted poll whose prev poll for the same napi —
serialized, race-free — rescheduled; per-peer flag `dbg_prev_resched`).

**Mechanism (traced in code):** peer NAPI is SCHED → completion's `napi_schedule` is a
no-op that sets `NAPI_STATE_MISSED` → at poll end `napi_complete_done` sees MISSED,
reschedules, returns false → re-poll → head now UNCRYPTED (crypted run already
delivered) → work_done==0 wasted. Producer-side gating can't catch it: at wake time
you can't know what the poll will have consumed by completion, and `queue->tail` is a
stale racing read while a poll is peeking. Decision belongs on the consumer side.

**RESULT (trace @8p) — CONFIRMED:**
- polls = 2,819,690 · wasted = 900,812 (31.9%) · resched = 1,609,978 (57%) ·
  wasted_after_resched = 897,901.
- **wasted_after_resched / wasted = 99.7%** → wasted polls are (essentially all)
  MISSED-driven re-polls. **Mechanism proven.**
- resched / polls = 57% (NAPI kept alive by MISSED). wasted / resched = 56% → of the
  reschedules, 56% are wasted, **44% (709k) are productive**.
- Sanity: in-module wasted 900,812 ≈ bpftrace WASTED 889,857 ✓.
- **Design consequence:** must suppress reschedules **selectively** (only when head
  UNCRYPTED) to keep the 44% productive ones. Lever is the consumer/poll side, where
  the head state is read authoritatively. Producer-side gating can't (racy tail read
  during active poll; can't predict what the poll consumes by completion). Safety: a
  naive MISSED-suppress risks lost wakeups → needs a timer backstop and/or head-recheck.

### 2026-06-19 — Phase D — trigger DESIGN written (`TRIGGER_DESIGN.md`)

- Lever identified: poll self-deschedules (`napi_complete_done` when work_done<budget),
  so the completion-side wake controls the *next* poll → coalesce the re-wake.
- Rule: count-or-timeout (K≈8–16, τ≈20µs, τ_max≈200µs), head-ready gated; defers the
  wake to build bigger batches, never wakes into an UNCRYPTED head.
- Grounded in costs: per-pkt cost flattens at K=8–16; ~4.7µs CPU saved per avoided
  poll; CPU-bound receiver → expect **throughput** to rise (what the M1 fix never did).
- Code map (5.15): hrtimer+atomic in `wg_peer`; gate in `wg_queue_enqueue_per_peer_rx`;
  timer callback does head-check + napi_schedule; K/τ as module params. Race: single
  timer owner via atomic_cmpxchg. Next: implement `wireguard_trigger.ko` (Phase E).

### 2026-06-19 — E3+E4+E5 cost model COMPLETE (stock @8p)

- **Clean poll cost** (`measure_pollcost.sh`, poll-only — no decrypt-probe inflation):
  C_poll = **1010 ns**, C_deliver ≈ **1.64 µs/pkt** (slope k=1..16), delivery-setup
  ≈ **3.7 µs** (intercept). Matches the decrypt-probed run → numbers are robust.
- **`measure_gro.sh`:** `@gro_ns` mode ~1 µs/pkt (tail ~10µs = GRO flush up stack) →
  part of C_deliver. `@delta_ns` (per-core decrypt gap) **bimodal**: ~4–8 µs (core
  cranking back-to-back, ≈ T_decrypt) and ~64–256 µs (idle between bursts).
- **Cost-model table now filled** (see summary table above).
- **Trigger design the data supports:** when a poll hits an UNCRYPTED head, the next
  completion is ~5–10 µs away (active cadence). A trigger that **delays the wake/poll
  by ~5–10 µs (or until ≥k packets ready)** lets the head + followers crypt, turning
  the 0–4-packet polls into bigger batches and amortizing the ~3.7 µs/poll setup —
  for only a few µs of added latency. Break-even: batching saves ~3.7µs per avoided
  poll; the cost is the added delay bounded by Δ_complete.
- Cost of today's waste: 865k wasted polls × ~1µs ≈ 0.87s CPU; plus ~1.9M delivering
  polls × 3.7µs ≈ 7s of per-poll setup over 20s (across cores) — the setup overhead
  dominates, and bigger batches attack it directly.
- Caveat: single runs, N=8 only; want repeats + the 32/64/128 sweep to confirm the
  costs hold with more concurrency before finalizing the trigger threshold.

### 2026-06-19 — E2+E4 cost model (stock @8p) — first per-step costs

- `measure_cost.sh stock 8` (probes `decrypt_packet` + `wg_packet_rx_poll`).
- **T_decrypt ≈ 5–6 µs/packet** (mode bucket [4K,8K)ns, 6.85M of ~7.48M samples).
- **Poll cost is linear in work_done:** `@poll_avg_ns` = 1018, 5265, 7392, 9427,
  11252, … 30562 (k=16) … 164264 (k=64).
  - **C_poll (k=0, wasted) ≈ 1.0 µs.**
  - First-packet jump [0]→[1] = +4247 ns → **fixed delivery setup ≈ 3.6 µs** (after
    subtracting one C_deliver).
  - **C_deliver ≈ 1.66 µs/packet** (mean of diffs over k=1..16).
  - Per-packet cost: 5.3 µs @batch1 → 1.9 µs @batch16 → **batching prize C_stack ≈
    3.6 µs per avoided poll**.
- **Poll batch distribution (`@poll_cnt`) is bottom-heavy:** k=0:767k, 1:462k, 2:394k,
  3:291k, 4:202k, … 16:27k, ≥32: few hundred. Most polls deliver ≤4 packets → almost
  no amortization. **This is the quantified inefficiency the trigger must fix.**
- **Trigger implication:** delaying/coalescing so polls deliver ~8–16 instead of 0–4
  would amortize the ~3.6µs setup + cut the 1µs wasted polls. The affordable delay is
  bounded by `Δ_complete` (E3, next) and T_decrypt (~5µs/pkt → packets ready every
  few µs/core).
- **Caveats:** probing `decrypt_packet` on every packet (7M) adds overhead → absolute
  poll counts here (767k wasted) < un-probed measure_one (922k), and durations may be
  slightly inflated. For clean `C_poll`/`C_deliver`, re-run probing ONLY
  `wg_packet_rx_poll` (no decrypt probe). Single run; want repeats.

### 2026-06-19 — ★ DIAGNOSIS — why the fix is null on a real NIC (KEY RESULT)

Counter-instrumented build (`wireguard_diag.ko`, srcversion `5E90522…`) with
`wg_dbg_sched` (wake taken) / `wg_dbg_skip` (wake skipped), @8 peers:

- **sched = 6,778,058 · skip = 701,460** → total wake-attempts 7,479,518; the fix
  **skips 9.4%** of them. **So the fix DOES fire** (not a no-op — hypothesis 1 wrong).
- Yet wasted polls unchanged (diag 922,665 ≈ stock 911,900).
- **Mechanism (hypothesis 2 confirmed):** `napi_schedule` is mostly a **no-op under
  saturation**. 7.48M wake-attempts collapse into only **2.73M actual polls**
  (wasted 922k + useful 1,804k) → **~63% of napi_schedule calls do nothing** (NAPI
  already `SCHED`). The fix removes 9.4% of *calls*, drawn from a pool that's ~63%
  redundant, so the *poll* count (and wasted-poll count) barely moves.
- **Implication:** gating `napi_schedule` is the **wrong lever** on a saturated real
  NIC — under continuous traffic the peer NAPI is ~always already scheduled, so
  suppressing wake *calls* changes nothing. Explains the loopback↔real-NIC gap: on M1
  loopback the NAPI wasn't continuously scheduled, so each wake was more often *real*
  and gating it worked (−21.9%); on a saturated 10G NIC that regime vanishes.
- **Design consequence for the batching-aware trigger:** it must act at the **poll /
  delivery** level (when/whether the poll runs, or delay the poll to let the head
  crypt — connects to `C_poll`, `Δ_complete`), NOT at the `napi_schedule` call site.
- Caveat: single run; counters raced (slight undercount). The mechanism (no-op
  coalescing) is robust to that. Worth 2–3 repeats to harden the headline before the
  report, but the conclusion is mechanistically explained, not just empirical.

### 2026-06-19 — E1 A/B at 8 peers — ⚠ FIX SHOWS NO EFFECT on real NIC (key finding)

- Protocol: `measure_one.sh <mod> 8` (DUR=20, 4 streams/peer, 8 peers). Metric =
  wasted-poll fraction `@w/(@w+@u)`, exact `work_done==0`.
- **Stock:**   WASTED 911,900 · USEFUL 1,851,654 · total 2,763,554 → **33.0%**
- **Patched:** WASTED 905,486 · USEFUL 1,821,892 · total 2,727,378 → **33.2%**
- → **No improvement** (patched marginally worse, within noise). Histograms nearly
  superimposable. Same null result as 1 peer. **Contradicts M1 (−21.9% @8peer, ARM
  loopback).**
- Hypotheses (to test, do NOT yet conclude):
  1. Fix is a near no-op here — its skip branch (`rx_queue.tail` state == UNCRYPTED)
     may rarely fire under real-NIC timing (short queue / tail often = empty stub).
  2. Wasted polls come from NAPI re-poll dynamics the fix doesn't gate, not the
     individual `napi_schedule` calls it removes.
- **This is informative for the project** (motivates the batching-aware trigger), but
  needs verification it's not an artifact. Next: (a) check the fix actually *fires*
  (does patched issue fewer napi_schedule / skip the wake?), and/or (b) sweep higher
  peer counts (16/32/64/128) to see if any effect emerges; (c) repeats for variance.
- NB single runs each; but stock vs patched are SO close that noise isn't hiding a
  large effect — the effect is genuinely ~0 at N≤8 here.

### 2026-06-18 — E0.5 DONE — multi-peer (8 peers) live

- Ported the M1 loopback multipeer harness to the 2-node testbed: `gen` runs N
  client namespaces (`ns_c0..`), each a wg interface created in root ns then moved
  into the netns (so encrypted UDP egresses `enp6s0f1`), endpoint `192.168.1.1:51820`.
  `dut` wg0 (root ns) has N peers. Scripts: `scripts/cloudlab/setup_gen_clients.sh`,
  `setup_dut_peers.sh`. Node-to-node ssh works (root) → DUT scp's pubkeys from gen.
- Gotcha fixed: `sudo` + `~` ambiguity made the pubkeys file land in the wrong home;
  switched both scripts to fixed `/tmp/wg_clients`.
- Verified at N=8: `wg show wg0` → **8/8 peers with latest handshake**.
- Next: multi-peer A/B (wasted-poll fraction stock vs patched) — the test the 1-peer
  run couldn't show.

### 2026-06-18 — E0.3 DONE — stock + patched modules built on 5.15

- **Key finding:** kernel 5.15.0-177 already has WireGuard's `prev_queue` structure
  (Ubuntu backport; `peer->rx_queue` is `struct prev_queue` with `head/tail/empty`).
  So the **exact M1 patch applies unchanged** — no need to switch to a 6.1 kernel.
  `wg_queue_enqueue_per_peer_rx` is byte-identical to the v6.1 reference.
- Source: `linux-source-5.15.0` package → `~/linux-source-5.15.0`, built out-of-tree
  against `/lib/modules/$(uname -r)/build`.
- Patch (in `queueing.h`, scoped to the rx fn): add `struct sk_buff *tail;`; replace
  bare `napi_schedule(&peer->napi);` with the head-readiness conditional
  (`READ_ONCE(peer->rx_queue.tail)` + STUB check + `PACKET_STATE_UNCRYPTED` test).
  Backup at `queueing.h.orig`.
- Both compile clean. **srcversions differ** (proof the .ko differs):
  - stock   `81233F6EC2FD233DEE88680`
  - patched `069999A629FE3C5CC0EABD6`
- Saved: `~/wireguard_stock.ko`, `~/wireguard_patched.ko`. ("Skipping BTF generation
  … vmlinux" is harmless — module-BTF only; kernel BTF present for bpftrace.)
- A/B swap procedure: `sudo wg-quick down wg0; sudo rmmod wireguard;
  sudo insmod ~/wireguard_<stock|patched>.ko; sudo wg-quick up wg0` (verify with
  `cat /sys/module/wireguard/srcversion`).

### 2026-06-18 — E1 stock pre-check (1 peer) — ✅ EoI REPRODUCED off-loopback

**Go/no-go result: GO.** The wasted-poll signature is clearly present on real 10G
hardware with the stock module.

- Setup: stock in-tree module, **1 peer**, `iperf3` over the wg tunnel, 20s probe.
- **Wasted-poll fraction = `@zero/@polls` = 326,036 / 911,568 = 35.8%** (polls
  returning `work_done == 0`).
- `@workdone` (lhist step 1) — strongly multimodal:
  - `work_done=0`: 326,036 (**35.8%** — wasted polls)
  - `=1`:31,581 `=2`:19,719 `=3`:14,852 `=4`:12,757 `=5`:14,279 `=6`:17,626 `=7`:36,854
  - `=8`: 243,032 (**26.7%** — sharp mode at exactly 8; likely a NAPI/GRO batch
    quantum, investigate later)
  - `=9`:21,325 `=10`:7,949 … `=15`:6,850
  - `≥16`: 140,378 (**15.4%** — large batches)
- **Throughput (single peer, CPU-bound, NOT link-bound):**
  - single TCP stream: **4.75 Gbit/s**
  - `-P 8` parallel streams: **4.07 Gbit/s** (lower! + 3048 retransmits)
  - Reason: 1 peer = 1 NAPI = **1 core**; `-P 8` doesn't add cores, so we're
    single-core softirq-bound at ~4 Gbit/s, far under 10G line rate. This is the
    real-NIC manifestation of M1's "flat throughput on loopback" → now a hard
    ceiling. **Multi-core needs multiple peers (E0.5).**
- **Caveat earlier run** (width-4 bucket) overcounted the low end at 47.5%; the
  correct `==0` fraction is 35.8%.
- Next: E0.3 build stock+patched → re-run this at 1 peer for the A/B (does the fix
  cut the 35.8%?), then E0.5 to scale peers/cores.

### 2026-06-18 — E0.4 DONE — single-peer tunnel up

- Tunnel `wg0` survived overnight; wired the two peers and confirmed a handshake.
- Config (single peer, reusable):
  - `dut`: pub `8+ROmIIc9bFQ74dzb9nmENZ/7vxW3RUcmv5tOOIA2j8=`, tunnel `10.0.0.1/24`,
    listen 51820, peer = gen.
  - `gen`: pub `HM+9lQIl9nZkMgl4O0/IUiqt+GLHl+U6nByXPv2i2XQ=`, tunnel `10.0.0.2/24`,
    listen 51820, peer = dut, endpoint `192.168.1.1:51820`.
  - Link endpoints over `enp6s0f1`: `192.168.1.1` (dut) / `192.168.1.2` (gen).
- Verified: `ping -c3 10.0.0.1` from gen → 0% loss; `wg show` shows latest handshake.
- Next: R4 quick stock EoI sanity (wasted-poll histogram) → E0.3 build → E0.5 → E1.

### 2026-06-17 (end of day) — stop point, experiment extended

- **Phase-A provisioning done:** E0.1 (instantiate), E0.2 (verify HW/NIC/BTF), E0.6
  (symbol check) all complete and green. Environment-of-record table filled.
- **E0.4 (tunnel) started, not finished.** Ran the per-node keygen + `wg0` bring-up
  blocks on `dut` and `gen` (single peer, tunnel net 10.0.0.0/24, port 51820).
  **Still pending: exchange pubkeys (the two `wg set ... peer` lines) and confirm a
  handshake.** Pubkeys were not captured before stopping — re-read them tomorrow.
- **CloudLab lease extended** on 2026-06-17 (justification: multi-day kernel
  measurement campaign, bare-metal, cannot checkpoint). Budget was 3 of 144
  node-hours used at extension time.
- **Resume tomorrow at E0.4 finish → E1 quick stock EoI check → E0.3 build patched.**
  Exact commands saved in `CLOUDLAB_NEXT_STEPS.md` ("Resume here" section).

### 2026-06-17 — E0.1 / E0.2 — testbed live, environment partially verified

- **E0.1 DONE.** Profile `wg-recv-measure` instantiated on Wisconsin; both nodes
  ready: `dut` = c220g2-011308, `gen` = c220g2-011310. Hostname carried through
  (`dut.measure-eoi…`).
- **E0.2 in progress.** Kernel is `5.15.0-177-generic` (Ubuntu 22.04 GA LTS), not
  6.x — accepted: WireGuard in-tree since 5.6, 5.15 ships BTF + bpftrace. Experiment
  10G NIC is **`enp6s0f1`** (192.168.1.1/24); `enp1s0f0` is the public/control net.
  Other NICs (`enp1s0f1`, `enp6s0f0`) are DOWN.
- **Still pending:** `lscpu`, NIC speed + RX queues on `enp6s0f1`, BTF file check,
  `dpkg` tooling check, ping to gen. Updating the env table as they come in.
- Next: finish E0.2 checks → E0.6 symbol check → E0.3 build modules.

### 2026-06-17 — setup — plan + log created

- Created `CLOUDLAB_EXPERIMENTS_PLAN.md` (runbook, phases A–C) and this log.
- Testbed **not yet instantiated**. Profile `wg-recv-measure` exists and validates
  (`scripts/cloudlab/profile.py`); next action is E0.1 (Start Experiment).
- Working assumptions pending confirmation of Alain's June 15 decisions: node
  `c220g2`, peer scale 1→32 then 128, five-quantity cost model, bpftrace/BTF probes.
- Decision: do E0.2 (verify HW/BTF) before building modules, and E1 (EoI repro) as
  the go/no-go before the full cost model.
