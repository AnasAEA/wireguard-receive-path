# Experiment inventory

## 1. Receive-steering baseline

- **Question:** Can NIC flow hashing distribute multiple WireGuard tunnels?
- **Artifacts:** `data/cloudlab/cpu_sd_spread.csv`,
  `cpu_sdfn_spread.csv`, committed CloudLab logs.
- **Raw/analysis commit:** `61c0991`.
- **Harness:** `scripts/cloudlab/measure_spread.sh`.
- **Design:** eight tunnels, stock module, `sd` versus `sdfn`; two 15-s
  throughput repetitions/hash and one per-core snapshot/hash.
- **Endpoints:** aggregate throughput; receive-core busy/softirq distribution.
- **Status:** descriptive background.
- **Validity limitation:** the machine-readable aggregate summary was not
  committed; the two throughput ranges survive in the committed log.
- **Permitted claim:** about 4.1 to 9.0 Gb/s with receive work spread across
  several cores in this topology.

## 2. Wake-side experiments

- **Question:** Can producer- and consumer-side wake changes suppress polls that
  cannot advance ordered delivery?
- **Artifacts:** `all_20260624.csv` (`61c0991`) and
  `twosided_peersweep_20260626.csv` (`6b1200e`).
- **Harnesses:** `measure_all.sh`, `measure_missed.sh`.
- **Design:** initial four-condition experiment with five 15-s repetitions;
  final 8/16/32/64-peer sweep with one 15-s run/condition/peer count.
- **Primary descriptive endpoint:** wasted-poll fraction.
- **Secondary:** throughput and MISSED/fresh wake composition.
- **Status:** descriptive mechanism validation.
- **Permitted claim:** the final two-sided change reduced approximately 27% to
  13--15%.
- **Not permitted:** throughput, CPU, or user-latency benefit.

## 3. Decrypt-delay dose response

- **Question:** Does the intervention suppress a larger share of premature
  polls as decryption is made slower?
- **Raw:** `decsweep_20260706_0321.csv`, commit `cc5a920`.
- **Analysis:** `analyze_decsweep.py`, findings commit `3628426`.
- **Design:** delays 0/1/2/5/10 us x off/both x five repetitions; 50 valid
  30-s runs; 8 peers.
- **Filter:** `status=ok`.
- **Primary:** wasted-poll fraction.
- **Status:** exploratory/descriptive.
- **Validity limitation:** nominal `LOAD=2` delivered only about 0.96--1.05
  Gb/s; the paper reports the actual committed load.
- **Permitted claim:** removed fraction rose from 56% to 89% over tested doses.

## 4. Empty-poll cost accounting

- **Question:** Is the complete premature-poll population expensive enough to
  explain a user-level effect?
- **Raw:** `costacct_20260706_0539/` and `_0613/`; commits `0613ffd`,
  `1ec609b`; perf binaries `c9be457`.
- **Analysis:** findings commit `311253c`.
- **Harness:** `measure_cost_accounting.sh`.
- **Design:** delay 0/10 us x off/both, 30-s windows; BPF duration sums and perf.
- **Primary:** mean wasted-poll duration and total CE budget.
- **Status:** descriptive upper-bound measurement.
- **Validity gates:** use the per-cell provenance table in the final CloudLab
  log; reject cold windows. The valid native-delay/off perf cell is missing.
- **Permitted claim:** 1.14--1.36 us per measured wasted poll; about 0.022 CE
  stock budget at native delay.

## 5. Classified ordered-head blocking

- **Question:** Are blocked episodes caused by an empty queue or by an
  incomplete ordered head, and how long do they last?
- **Raw:** first run `stallclass_20260709_0727.csv` (`42006bd`); preferred
  spread-guaranteed rerun `stallclass_20260710_0332.csv` (`d0ea83b`).
- **Analysis:** `35142b6`.
- **Harness:** `measure_stall_class.sh`.
- **Design:** off, delays 0/5/10 us, three 30-s repetitions/delay, one row per
  class/window.
- **Endpoints:** episodes, total/max duration, mean, four duration buckets.
- **Status:** descriptive mechanism evidence.
- **Permitted claim:** the `UNCRYPTED` class had about 150k--298k episodes per
  window with means of about 35--94 us.
- **Not permitted:** equating episode duration with packet latency.

## 6. Initial work-stealing experiment

- **Question:** Can the blocked receive context service shared decrypt work and
  reduce classified head blocking?
- **Raw:** `steal_20260710_1542.csv`, commit `a23570a`.
- **Analysis:** CloudLab log commit `02b68e5`.
- **Harness:** `measure_steal.sh`.
- **Design:** off/both/steal8/bsteal8 x four shuffled 30-s repetitions; seven
  bulk peers plus a dedicated probe peer.
- **Endpoints:** blocking counters/time, pulls, CPU, throughput; latency fields
  retained but not used for claims.
- **Status:** exploratory feasibility/mechanism evidence.
- **Permitted claim:** stealing activated and reduced classified blocked wall
  time substantially.

## 7. Steal-budget sweep

- **Question:** Which bounded treatment should enter confirmation?
- **Raw:** `single_20260715_0516.csv`, commit `384e6ab`.
- **Analysis:** `analyze_single.py`, commit `2b272ac`.
- **Design:** single tunnel, uncapped `iperf3 -P 4`, steal values
  0/1/2/4/8/16 x five shuffled 20-s repetitions.
- **Statistics:** exact independent permutation test for each value versus off;
  252 allocations; Bonferroni threshold 0.01.
- **Status:** exploratory treatment selection.
- **Permitted claim:** budget four was selected for confirmation.
- **Not permitted:** global optimality or use of the sweep estimate as the
  final effect.

## 8. Saturated paired confirmation

- **Question:** Does steal4 raise throughput and reduce total busy CPU under an
  uncapped single-tunnel bottleneck?
- **Raw:** `confirm_20260716_090437.csv`, `.meta`, `.percore`, `.dmesg`, 48
  raw JSONs; commit `fc9fd60`.
- **Analysis:** `.analysis.txt`, commit `87fb8d4`.
- **Harness/analyzer provenance:** `9c2c35f514652d685527db0a0e0363ba1f55540e`;
  `analyze_confirm.py`.
- **Design:** 12 randomized paired blocks x off/both/steal4/bsteal4; 48
  complete 30-s runs on the same instantiation after a controlled reset.
- **Co-primary endpoints:** throughput and total busy CE for `steal4-off`.
- **Secondary:** throughput per busy CE and factorial composition.
- **Statistics:** exact paired sign-flip test; 10,000-resample paired bootstrap
  CI; Holm adjustment for the secondary family.
- **Validity:** complete blocks, exact knob readbacks, raw identity, all
  sidecars/JSONs, zero relevant dmesg records, analyzer exit 0.
- **Result:** +1.96% throughput, -3.66% total CPU; both co-primaries favorable.
- **Limitation:** same-instantiation confirmation is not fresh-node replication.

## 9. Withdrawn loaded-tunnel latency smoke

- **Question:** Can loaded-tunnel Sockperf percentiles be compared at matched
  throughput?
- **Raw:** `fixedload_smoke_20260717_030207*`, commit `94f8271`.
- **Design:** one four-condition block; approximately 62-s runs.
- **Status:** invalid and withdrawn.
- **Failure:** absolute-load units mismatched and the closed-loop UDP probe
  froze after unanswered packets, leaving condition-dependent valid durations.
- **Permitted use:** document why no latency claim is made.

## 10. CPU-only matched-load smoke

- **Question:** Does the redesigned CPU-only workflow produce complete,
  exactly identified artifacts without Sockperf?
- **Artifacts:** `fixedload_cpu_smoke_20260717_095036*` and `_100151*`;
  raw commit `63b125a`.
- **Harness/analyzer:** final audited version `d6dae228c1142a751915e72b62a7164f9cbd8034`.
- **Design:** two one-block x four-condition 60-s smoke attempts.
- **Status:** structural smoke only; no scientific verdict.

## 11. Full matched-load CPU confirmation

- **Question:** At matched delivered load, does steal4 reduce total busy CPU?
- **Raw:** `fixedload_cpu_20260718_024625.csv`, sidecars, 32 raw JSONs; commit
  `63b125a`.
- **Analysis:** `.analysis.txt`, commit `f50dd08`.
- **Harness/analyzer provenance:** `d6dae228c1142a751915e72b62a7164f9cbd8034`.
- **Design:** eight randomized paired blocks x four conditions; 32 exact 60-s
  windows; `CPU_ONLY=1`; target 3.8 Gb/s delivered at `wg0`.
- **Primary:** total busy CE for `steal4-off`.
- **Secondary:** Holm-adjusted composition comparisons.
- **Descriptive:** softirq/per-core and mechanism counters.
- **Validity:** 3.8012--3.8027 Gb/s, max target deviation 0.071%, worst required
  paired mismatch 0.0316%, 1,280 unique per-core tuples, 32 JSONs, no Sockperf,
  zero relevant dmesg records.
- **Result:** -0.047 CE (-1.17%), CI95 [-0.245,+0.134], exact p=0.6562;
  3/8 blocks favorable. No favorable CPU effect was detected.
- **Not permitted:** absence, equivalence, or an exclusive saturation threshold.
