# Phase D — Batching-aware trigger: design

> From the cost model (`CLOUDLAB_EXPERIMENTS_LOG.md`) to a concrete, implementable
> trigger. Target module variant: `wireguard_trigger.ko`, A/B vs stock, re-measured
> with the same probes.

## 1. Why the current lever fails, and what the right one is

The 6-line fix gates `napi_schedule` at decrypt completion. Measured null on a real
NIC because **`napi_schedule` is ~63% no-op under load** (the peer NAPI is usually
already `SCHED`). So suppressing *wake calls* doesn't change the number of *polls*.

But the poll **does** deschedule itself: `wg_packet_rx_poll` calls
`napi_complete_done` whenever `work_done < budget`, which is almost always (budget 64,
most polls deliver <16). **So after each poll the NAPI is unscheduled, and the
completion-side wake genuinely controls the *next* poll.** That is the lever: not
*whether* to wake, but *when* — coalesce the re-wake so the next poll delivers a
bigger batch.

## 2. The numbers that set the policy

| quantity | value | role in the policy |
|----------|-------|--------------------|
| `C_poll` (empty poll) | ~1.0 µs | overhead of a poll that delivers nothing |
| delivery setup | ~3.7 µs | fixed cost once a poll delivers ≥1 — the amortizable part |
| `C_deliver` | ~1.64 µs/pkt | marginal per-packet cost |
| `T_decrypt` | ~5–6 µs | how fast packets become ready |
| `Δ_complete` | ~5 µs active / ~100 µs idle | how long to wait for the next packet |

Per-packet cost = `setup/k + C_deliver`: **2.1 µs at k=8, 1.87 µs at k=16** vs 5.3 µs
at k=1. Diminishing returns past ~8–16 → **target batch k ≈ 8–16**. Merging two polls
saves ≈ `C_poll + setup` ≈ **4.7 µs** of CPU per avoided poll, at the cost of ≤ τ added
latency. The receiver is **CPU-bound** (one softirq core saturates at ~4 Gb/s, far
below 10G line rate), so trading a few µs of latency for CPU is a throughput win.

## 3. The trigger rule

Coalesce the decrypt-completion → NAPI wake with a **count-or-timeout** policy, gated
on head readiness:

```
on decrypt completion for peer P (wg_queue_enqueue_per_peer_rx):
    if NAPI already scheduled:            return        # nothing to do
    if head(P) not ready (UNCRYPTED):     ensure deadline timer armed; return
    ready++                                              # contiguous-ready estimate
    if ready >= K:        cancel timer; napi_schedule(P); ready = 0
    else:                 ensure coalesce timer armed (τ)

timer fires (per peer):
    if head(P) ready:     napi_schedule(P); ready = 0
    else if elapsed < τ_max: re-arm (bounded)            # head still stalled
    else:                 napi_schedule(P); ready = 0    # liveness backstop

wg_packet_rx_poll: unchanged (still head-first, ordered); resets `ready` on entry.
```

- **K** (count) bounds batch size and fires fast under heavy load.
- **τ** (coalesce window) lets followers accumulate when traffic is light; **τ_max**
  guarantees liveness if the head stalls.
- **head-ready gate** is what cuts the zero polls: we don't wake into an UNCRYPTED head.

**Defaults (to sweep): K = 8, τ = 5 µs, τ_max = 100 µs.** All module params so we can
sweep without recompiling.

> **τ is now data-driven, not guessed** (was 20 µs). The re-poll-gap measurement
> (`measure_repoll_gap.sh`, 2026-06-22) showed the natural re-poll fires at median
> ~1.6 µs — a coin flip (≈49% wasted). Useful fraction climbs to **67% by 2–4 µs** and
> plateaus (~72%) by 8–16 µs, i.e. the knee is at **≈ one `T_decrypt`**. So τ ≈ 4–5 µs
> captures most of the benefit; past ~8 µs you pay 2–4× the latency for ~5 pp. Sweep
> τ ∈ {4, 6, 8, 12} µs and read the wasted-poll / batch-size knee. (`τ_max` tightened
> to 100 µs accordingly — the idle-gap tail sits at ~100 µs.)

### First prototype (simplest that tests the hypothesis)

Pure **τ-coalescing with a head-ready timer callback**, no `ready` counter:
- completion: if NAPI not scheduled and no timer pending, arm hrtimer(τ).
- timer: if head ready → `napi_schedule`; else re-arm up to τ_max.

This already batches everything completing within τ and avoids waking into a stalled
head. Add the `K` fast-path second.

## 4. Where it goes in the 5.15 source

| change | file | what |
|--------|------|------|
| per-peer state | `peer.h` (`struct wg_peer`) | add `struct hrtimer rx_coalesce_timer;` + `atomic_t rx_timer_armed;` (+ optional `rx_ready` counter) |
| init / teardown | `peer.c` | `hrtimer_init(..., CLOCK_MONOTONIC, HRTIMER_MODE_REL_SOFT)` + set `.function`; `hrtimer_cancel` in peer free/remove |
| timer callback | `queueing.c` or `receive.c` | reads peer, checks head readiness (`wg_prev_queue_peek` state), `napi_schedule(&peer->napi)`, returns `HRTIMER_NORESTART` (or re-arm) |
| the trigger | `queueing.h` (`wg_queue_enqueue_per_peer_rx`) | replace the bare `napi_schedule` with the count-or-timeout logic |
| params | `main.c` | `module_param` for `wg_trig_k`, `wg_trig_tau_ns`, `wg_trig_taumax_ns` |

**Concurrency note (the hard part):** multiple decrypt workers complete packets for the
same peer on different cores concurrently, all reaching the trigger. Use
`atomic_cmpxchg` on `rx_timer_armed` so exactly one core arms/owns the timer; the
timer callback clears it. `napi_schedule` and `hrtimer_start` are both safe from
worker/softirq context. Head readiness is a single `READ_ONCE` of the peeked packet's
state — a read-only hint, same safety argument as the original fix.

**Liveness:** the timer guarantees a wake within τ_max even if the head stalls → no
packet stranded. Ordering is untouched (poll still delivers head-first).

### As built (2026-06-23, `wireguard_trigger.ko`, srcversion `3076ED3…`)

Two deliberate deviations from the sketch above, both for concurrency safety, plus one
packaging win:

1. **Readiness = the `rx_ready` counter, not a head peek.** The design's "head-ready
   gate" reads `wg_prev_queue_peek`, but that is **single-consumer** (only the NAPI poll
   may touch `queue->peeked`). The trigger runs in the multi-core decrypt workers, so
   peeking there would race the `peeked` pointer. Instead each CRYPTED completion does
   `atomic_inc_return(&peer->rx_ready)` (reset on poll entry) — the same contiguous-ready
   estimate the K fast-path already needs, and race-free. The K path fires on
   `rx_ready >= K`; otherwise one timer is armed via `atomic_cmpxchg(rx_timer_armed,0,1)`.
2. **Single-shot timer ⇒ τ_max ≡ τ.** The timer callback just clears the armed flag and
   `napi_schedule`s (NORESTART); it does **not** re-check head readiness or re-arm, for
   the same single-consumer reason. The τ delay already gives decrypt ~one `T_decrypt` to
   finish; if the head is still UNCRYPTED the poll bails cheaply, exactly like a stock
   wake. So the first prototype's τ_max backstop collapses into τ itself.
3. **One binary, runtime knob.** `wg_trig_k` is a module param: `0` ⇒ the bare immediate
   `napi_schedule` (byte-identical stock), `≥1` ⇒ trigger. `wg_trig_tau_ns` sets τ. So
   the A/B (`k=0` vs `k=8`) toggles a knob on the *same loaded module* — eliminating the
   base-divergence and reload-variance confounds entirely. Build is clean-room from
   pristine 5.15 source (the on-dut tree was contaminated); patch in `build/wg515-trigger/`.

Teardown safety: `hrtimer_cancel` runs in `peer_remove_after_dead` *after* the crypt_wq
flushes, so no decrypt worker can re-arm the timer past that point and the cancel waits
out any in-flight callback before napi is disabled.

## 5. Validation plan (Phase E)

Build `wireguard_trigger.ko` from **stock** (not the null fix) + the above. Then, at
8/16/32 peers, A/B trigger vs stock, ≥5 runs:

1. **Wasted-poll fraction** (`measure_one.sh`) — expect it to drop (we stop waking into
   uncrypted heads).
2. **Batch distribution** (`measure_pollcost.sh` `@poll_cnt`) — expect mass to shift
   from k=0–4 toward k=8–16.
3. **Throughput** (iperf SUM) — expect it to *rise* (CPU freed from per-poll overhead),
   since we're CPU-bound. **This is the headline the M1 fix never moved.**
4. **Latency** — added delay should be ≤ τ (tens of µs); confirm tail latency stays
   acceptable.
5. **Sweep K and τ** (module params) to find the knee, then cross-check against the
   cost-model prediction (per-packet cost vs k).

Loop: measure → adjust K/τ → re-measure.

## 6. Risks

| risk | mitigation |
|------|------------|
| timer arm/cancel races across cores | single-owner via `atomic_cmpxchg(rx_timer_armed)` |
| added latency hurts a latency-sensitive flow | τ small (tens of µs); τ is a tunable param; bounded by τ_max |
| hrtimer overhead per peer exceeds the saving | coalesce so ≤1 timer per batch; measure timer cost; fall back to K-only if needed |
| head-of-line stall (head's core slow) | τ_max backstop; this is inherent to ordered delivery, not made worse |
| extra per-peer state grows `wg_peer` | one hrtimer + one atomic; negligible |
