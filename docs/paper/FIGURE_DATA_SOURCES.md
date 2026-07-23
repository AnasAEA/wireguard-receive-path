# Figure data sources and regeneration rules

The authoritative generator is `scripts/paper/make_figures.py`. All output is
written as vector PDF to `paper/figures/generated/`. The script must fail rather
than substitute missing evidence or silently accept incomplete paired blocks.

## Figure A: steering baseline

- **Output:** `paper/figures/generated/steering_baseline.pdf`
- **Raw:** `data/cloudlab/cpu_sd_spread.csv`,
  `data/cloudlab/cpu_sdfn_spread.csv`.
- **Columns:** `core`, `busy_pct`, `softirq_pct`.
- **Throughput context:** 4.08--4.13 Gb/s (`sd`) and 8.99 Gb/s (`sdfn`), parsed
  from `docs/cloudlab/CLOUDLAB_EXPERIMENTS_LOG_RAW.md` because the original
  `spread_*.txt` was not committed.
- **Filter:** all numeric core rows.
- **Units:** percent of one logical CPU.
- **Aggregation:** order cores by softirq consumption; show observed core
  distributions, no inferential interval.
- **Status:** background/descriptive.

## Figure B: decrypt-delay mechanism

- **Output:** `wake_delay_response.pdf`
- **Raw:** `data/cloudlab/decsweep_20260706_0321.csv`.
- **Columns:** `delay_ns`, `condition`, `wasted_frac`, `status`.
- **Filter:** `status == "ok"`; conditions `off` and `both`.
- **Units:** delay ns/1000 to us; fraction x100 to percent.
- **Aggregation:** median and interquartile range over five repetitions;
  individual points retained.
- **Statistics:** descriptive; no confirmatory CI.

## Figure C: empty-poll cost and CPU budget

- **Output:** `empty_poll_cost.pdf`
- **Raw:** documented valid `bpf_*.txt` cells under
  `costacct_20260706_0539/` and `_0613/`.
- **Fields parsed:** `@wasted`, `@wasted_ns`.
- **Valid provenance:** native/off from `_0613`; native/both from valid cells;
  10-us/off from `_0613` for comparable load; 10-us/both from `_0539`.
- **Units:** `mean_us = total_ns/count/1000`;
  `CE = total_ns/(30*1e9)`.
- **Aggregation:** one point per valid cell; no invented error bar.
- **Statistics:** descriptive upper-bound measurement.

## Figure D: classified head blocking

- **Output:** `classified_blocking.pdf`
- **Raw:** `data/cloudlab/stallclass_20260710_0332.csv`.
- **Columns:** `delay_ns`, `rep`, `class`, `episodes`, `mean_us`, `le16us`,
  `le128us`, `le1ms`, `gt1ms`.
- **Filter:** `class == "uncrypt"` for the main panel.
- **Units:** delay ns/1000 to us; durations already us.
- **Aggregation:** all three repetition points plus median/range per delay.
- **Bucket semantics:** <=16 us, 16--128 us, 128 us--1 ms, >1 ms.
- **Statistics:** descriptive mechanism evidence.

## Figure E: saturated paired confirmation

- **Output:** `gate_a_paired.pdf`
- **Raw:** `data/cloudlab/confirm_20260716_090437.csv`.
- **Analysis/statistics:** `confirm_20260716_090437.analysis.txt`.
- **Columns:** `block`, `cond`, `gbps`, `total_busy_ce`.
- **Filter:** complete blocks with exactly one off and one steal4 row.
- **Contrasts:** within-block `steal4-off`.
- **Units:** throughput percent relative to mean off; CPU percent relative to
  mean off.
- **Aggregation:** mean paired delta.
- **CI:** values parsed from the committed analysis file; the analyzer used
  10,000 paired bootstrap resamples with a fixed seed.
- **P-value:** exact two-sided paired sign-flip value parsed from analysis.
- **Display:** all 12 block deltas, zero reference, mean and CI.
- **Status:** confirmatory co-primary.

## Figure F: matched-load CPU confirmation

- **Output:** `gate_b_matched.pdf`
- **Raw:** `data/cloudlab/fixedload_cpu_20260718_024625.csv`.
- **Analysis/statistics:** `fixedload_cpu_20260718_024625.analysis.txt`.
- **Columns:** `block`, `position`, `cond`, `load_window_gbps`,
  `total_busy_ce`.
- **Filter:** eight complete blocks, exact off/steal4 pairing.
- **Left panel:** all 32 delivered loads with target line at 3.8 Gb/s.
- **Right panel:** all eight paired `steal4-off` CPU deltas.
- **CI:** committed paired-bootstrap interval [-0.245,+0.134] CE.
- **P-value:** exact sign-flip p=0.6562.
- **Status:** confirmatory primary non-detection.

## Commands

From the repository root:

```sh
python3 scripts/paper/make_figures.py --all
python3 scripts/paper/make_figures.py --figure gate-a
python3 scripts/paper/make_figures.py --figure gate-b
```

Or from `paper/`:

```sh
make figures
```

The expected outputs are PDFs with embedded fonts, publication-sized text,
color-blind-safe colors, and marker/line distinctions that remain readable in
grayscale.
