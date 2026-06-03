# Improved EoI experiment — run guide

Run this on the **Fedora Asahi box** (the WireGuard module, bpftrace, and netns are
Linux-only; it cannot run from the macOS checkout). It produces the measured figure
that replaces the illustrative `fig:emptypoll` in the report.

## What this fixes vs the May 28 run

| Problem on May 28 | Fix here |
|---|---|
| Load and peer count entangled (4 streams/peer → 1 peer = 1.5 Gbps, 8 peers = 13 Gbps). Could not tell whether "no effect at 1 peer" was about peers or about low load. | **Total load held constant.** `TOTAL_STREAMS` is split across peers, so every cell offers the same traffic. The 1-peer cell now runs at full load — the control that was missing. |
| Stock vs patched compared across two separate module loads (different memory layout, page cache). | **In-module toggle** `wg_eoi_fix` (sysfs) flips the guard in place — same module, same tunnel. Needs the module from `admin/PATCH_DECRYPT_DELAY.md`; falls back to reload otherwise. |
| Single run per cell; no variance bars. | **Repeated, interleaved runs**; stock/patched order alternates each run so drift cancels. Medians + IQR error bars. |
| Crypto too fast on M1 to reach the paper's throughput-collapse regime. | Optional **`DELAY_US`** injects per-packet decrypt cost to approach that regime. |
| Output not plot-ready. | CSV → `plot_improved.py` → report-ready PDFs. |

## Prerequisites

- Patched, delay-capable module loaded (from `admin/PATCH_DECRYPT_DELAY.md`) so that
  `/sys/module/wireguard/parameters/wg_eoi_fix` exists. Check:
  ```bash
  ls /sys/module/wireguard/parameters/   # expect wg_eoi_fix, wg_decrypt_delay_us
  ```
  If absent, the harness still works by reloading stock/patched modules, but you lose
  the in-place toggle and cannot use `DELAY_US`.
- `iperf3`, `bpftrace`, `python3`, and (for plotting) `matplotlib`
  (`pip install --user matplotlib`).

## Run

```bash
cd <repo>
# Full fixed-load peer sweep: peers {1,2,4,8,16,32}, 32 total streams, 5 runs each, 30 s.
sudo bash scripts/run_improved.sh

# Explicit / custom:
#   PEERS            TOTAL_STREAMS RUNS DURATION DELAY_US MODE        KEEP_CPUS
sudo bash scripts/run_improved.sh "1 2 4 8 16 32" 32 5 30 0 ecores

# Regime test (heavier crypto, 2-core contention) to chase the throughput effect:
sudo bash scripts/run_improved.sh "16" 32 5 30 40 bottleneck "0 1"
```

Each cell writes a run dir under `results/improved_<stamp>_.../` and appends to
`MANIFEST.csv`. At the end the harness prints the summary and the plot command.

## Analyze + plot

```bash
PARENT=results/improved_<stamp>_load32_ecores     # printed by the run
python3 scripts/analyze_improved.py "$PARENT"      # prints Markdown, writes SUMMARY.csv + runs_long.csv
python3 scripts/plot_improved.py   "$PARENT"       # writes $PARENT/figures/*.pdf
```

Figures produced:

- `eoi_wasted_polls.pdf` — empty (wasted) polls/s, stock vs patched, vs peers (the headline RQ1/RQ3 figure).
- `eoi_total_polls.pdf` — total NAPI polls/s (what the fix actually reduces).
- `eoi_batch_mean.pdf` — mean `work_done` per delivering poll (the GRO-consolidation evidence).
- `eoi_combined.pdf` — the three panels side by side.

## Reading the result honestly

- **The control is `peers = 1` at full load.** If the patch now *also* suppresses polls
  at 1 peer, the effect is driven by offered load / per-queue concurrency, not by the
  number of peers. If it still does nothing at 1 peer despite full load, the effect is
  genuinely per-peer. Either way the caption can state which.
- **Batch mean is the strongest evidence.** Throughput is pinned at the loopback/ChaCha20
  ceiling, so the GRO benefit shows up as fewer-but-fatter polls, not as Gbps. A rise in
  mean `work_done` under the patch, with throughput flat, *is* the GRO improvement.
- **Throughput / tail-latency deltas on this rig are not evidence** for the paper's
  regime (loopback never saturates `NET_RX_SOFTIRQ`). Report them with that caveat;
  the throughput regime is the CloudLab/x86 job.

## Wiring into the report

Copy the chosen PDF into `report/figures/` and replace the illustrative figure:

```latex
\includegraphics[width=\linewidth]{eoi_wasted_polls.pdf}
```

Then drop the "Illustrative, not yet measured" caption and the matching TODOs, and
update the "we expect the baseline rate to climb" paragraph to what was observed.
