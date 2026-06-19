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

---

## Cost-model summary (the headline table)

The deliverable of Phase C. Fill as E2–E5 produce numbers. Medians; note units.
Keep stock and patched side by side.

| Quantity | Source (plan) | Stock @8p | Patched | Notes |
|----------|---------------|-------|---------|-------|
| `T_decrypt` (per packet) | E2 | **~5–6 µs** | — | mode [4K,8K)ns, 6.85M samples; probed `decrypt_packet` |
| `Δ_complete` (inter-completion) | E3 | — | — | per-peer median (TODO) |
| `C_poll` (empty/wasted poll) | E4 | **~1.0 µs** | — | `@poll_avg_ns[0]`=1018 ns |
| delivery setup (fixed, k≥1) | E4 | **~3.6 µs** | — | jump [0]→[1] = 5265−1018 minus 1×C_deliver |
| `C_deliver` (per packet in poll) | E4 | **~1.66 µs** | — | slope of `@poll_avg_ns` over k=1..16 |
| `C_stack` (GRO benefit / poll) | E5 + E6 | **~3.6 µs** | — | = delivery-setup amortized; per-pkt cost 5.3µs@batch1 → 1.9µs@batch16 |

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
