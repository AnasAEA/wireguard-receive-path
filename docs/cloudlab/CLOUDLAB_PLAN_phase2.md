# Phase 2 plan — does the removed work matter at the system level?

> We are past "is the mechanism real?" (it is: the two-sided fix halves wasted polls,
> ~27% → ~14%, flat across 8–64 peers — see `RECEIVE_PATH_FINDINGS.md` §2b). Phase 2 asks
> the harder question: **on real c220g2 hardware, does that removed work translate into a
> user-visible gain (CPU efficiency, tail latency), and in which operating region?**
> The harness must produce a result that is interpretable *either way* — a clean win or a
> defensible null. Author: Anas Ait El Hadj · Inria KrakOS.

## The central risk

The danger is not a weak idea; it is an **ambiguous null** ("we removed wasted polls but
latency/CPU did not clearly move"), which could mean any of: the fix truly doesn't matter
here; wrong load point; insensitive latency probe; CPU measured at the wrong layer; tool
noise dominating; bottleneck elsewhere; or a real effect below measurement resolution. The
harness is designed to separate these.

## Phase A — sub-saturation latency + CPU (`measure_subsat.sh`)

At line rate the fix cannot help (throughput-bound). With headroom, a saved ~1 µs poll on
the receive core *might* show in the tail or in CPU. So: hold a fixed capped bulk load,
reserve one peer for a request/response latency probe, measure latency and CPU together.

**Design**
- **Topology.** `peer 0` = latency only (sockperf ping-pong, TCP, no bulk on it). `peers
  1..N-1` carry a capped TCP bulk load (`iperf3 -b`, multiple streams). Same WireGuard
  config family, same `sdfn` spread, same receive host, same CPU-contention domain — so the
  latency flow shares the receive path with the bulk peers but isn't self-loaded.
- **Load sweep.** Nominal totals 0 / 2 / 4 / 6 Gb/s. **0 Gb/s is the baseline** (native
  jitter / C-state floor). Targets are *nominal*: `iperf3 -b` pacing undershoots ~20–30%,
  so **analysis bins by `load_actual_gbps`**, not target. off and both at one target see the
  same generation → same actual → valid comparison.
- **Conditions.** `off / supp / root / both` (run all four during validation; final figures
  may show only off vs both). If only `both` improves things → supports the two-sided
  mechanism. If `supp` gives most of it → headwake is optional. If `headwake` is unstable →
  we already have the safe `supp`-only fallback.
- **Latency tool: sockperf** (not netperf). sockperf reports p50/p99/**p99.9** natively;
  netperf omni tops out at p99. ~1500 RTT/s → a 30 s run gives ~45k observations (p99.9 has
  ~45 samples; p99.99 is too thin to trust here).
- **CPU: three metrics, not just softirq** (softirq alone can miss the cost):
  `softirq_ce` (sum core softirq Δ / wall) — the sensitive WG-receive lens;
  `system_ce` (system+irq+softirq); `total_busy_ce` (all non-idle). All in cores-equivalent.
- **Verified load + reject gate.** Every run records target *and* actual receiver throughput
  (sum of iperf3 `sum_received`) + TCP retransmits. A run is flagged if
  `|actual−target|/target > REJECT_DEV` (default 0.40 — catches *collapses*, not pacing slop).
- **Placement recorded** (the first result was about flow/core placement): NIC rx-flow-hash,
  `ethtool -l`, per-IRQ `smp_affinity_list`, governor, NUMA → sidecar `*.placement.txt`.
- **Reps shuffled.** `(load × cond × rep)` order randomized to decorrelate drift; ≥6 reps.

**Per-run CSV row** (`subsat_<ts>.csv`):
```
date,commit(srcversion),host,condition,peers,load_target_gbps,load_actual_gbps,
latency_tool,lat_samples,p50_us,p99_us,p999_us,
softirq_ce,system_ce,total_busy_ce,
wasted_poll_pct,fresh_wake_pct,retransmits,drops,nic_irq_count,sdfn_state,notes
```
`wasted_poll_pct`/`fresh_wake_pct` are **NA** here on purpose — a bpftrace probe would
perturb the latency window. They are cross-referenced from `measure_missed.sh` (already
characterized: flat ~27% → ~14% across 8–64 peers).

**Run it**
```bash
# default: off vs both, loads 0/2/4/6, 6 reps, 30 s
sudo bash ~/measure_subsat.sh 8 "0 2 4 6"
# all four conditions during validation:
CONDS="off supp root both" REPS=8 sudo bash ~/measure_subsat.sh 8 "0 4"
```

**Known harness risks (watch these when reading results)**
1. **Bulk-receiver CPU noise.** The N−1 `iperf3 -s` receivers on the dut burn ~10 of 40
   cores and inject scheduling jitter that can swamp the µs-scale wasted-poll signal in the
   latency tail (seen in early 2-rep runs: `both` p99 wasn't clearly better; `busy_ce` varied
   7.8↔12.0 for the *same* condition). Mitigations to try if the signal is buried: pin the
   iperf3 servers to a core set disjoint from the NIC-RX cores; or use a lighter bulk sink.
2. **Idle ≠ low latency.** With `schedutil`, the 0-load baseline shows *higher* p50 (~338 µs)
   than light load (~130 µs) because idle cores drop frequency / enter C-states. The tail
   (p99/p999) is where load actually shows. Interpret p50 with this in mind; consider
   `performance` governor as a control.
3. **Single-tunnel TCP ceiling.** Per-peer RX is one NAPI; a tunnel tops out ~1 Gb/s for one
   stream. Hence multiple streams per bulk tunnel, and bin by actual.

## Phase B — decrypt-cost sweep (sensitivity, not the main claim)
`measure_decrypt_sweep.sh`, fixed: run at a **capped sub-line-rate load** so slowing decrypt
doesn't implode the pipeline; fix the throughput capture. Sweep `wg_decrypt_delay_ns` =
0/1/2/5/10 µs. Per point: actual throughput, wasted%, CPU CE, p50/p99/p999, retransmits.
Identify the **knee** (safe / transition / collapse); only the safe+transition region is
evidence. Answers "under what decrypt:poll ratio does the fix become visible," explaining why
it may be invisible on fast crypto.

## Phase C — `headwake` reliability soak (gate before recommending `both`)
Sustained load with `wg_headwake=1` for 15–30 min at moderate **and** near-line-rate load;
watch for throughput collapse, handshake timeouts, dmesg warnings, RCU stalls, loss. If it
passes, recommend `both`. If not, the fallback is clean: "consumer-side suppression is safe
and removes part of the wasted work; producer-side gating is promising but needs
memory-ordering hardening."

## How we will state the result (avoid overclaiming)
Not "the fix improves WireGuard performance." Instead:

> The two-sided fix removes a measurable class of wasted WireGuard polling work. On c220g2
> this does not improve saturated throughput, because that is dominated by receive-side
> parallelism and NIC flow placement. The open question is whether the saved work reduces
> CPU or tail latency under sub-saturation.

Then, depending on results:
- **A finds a win:** "at sub-saturation the fix converts reduced polling into measurable CPU
  savings and/or lower tail latency; the effect appears only with receive-core headroom."
- **A null, B finds a win:** "on the fast c220g2 crypto path the saved work is below the
  CPU/latency noise floor; under higher decrypt cost the benefit emerges — it matters when
  the decrypt:poll ratio is high."
- **A and B null:** "the fix is mechanically correct and halves wasted polls, but on this
  hardware/workload the removed work is not a first-order contributor to CPU or tail latency;
  the bottlenecks are elsewhere." (Valid, given a clean methodology.)

## Order
A first (it holds the answer and subsumes the CPU-efficiency test), B second (shares A's
capped-load driver), C in parallel (unattended soak), then write up. The lease resets daily,
so each session starts with `bootstrap_testbed.sh`; keep runs session-sized.
