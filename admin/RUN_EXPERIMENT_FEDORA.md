# Running the improved EoI experiment — Fedora Asahi

Pull the repo, run one command, get the figures.

---

## 0. Pull the latest scripts

```bash
cd <repo>
git pull
```

---

## 1. Check the module

The improved harness uses an in-module sysfs toggle (`wg_eoi_fix`) to flip stock vs
patched *without reloading the module*. This gives cleaner measurements. You need the
delay-capable patched module (from `admin/PATCH_DECRYPT_DELAY.md`) loaded.

```bash
ls /sys/module/wireguard/parameters/
# expected output: wg_decrypt_delay_us  wg_eoi_fix
```

If the knobs are there, you're good. If not, rebuild and load the patched module first
(see `admin/PATCH_DECRYPT_DELAY.md`), then re-check.

> **Fallback:** if the knobs are absent the harness still works — it just reloads stock
> vs patched modules between cells. The results will be noisier. In that case make sure
> `load_stock.sh` and `load_patched.sh` are configured for your paths.

---

## 2. Install plotting dependency (one-time)

```bash
pip install --user matplotlib
```

---

## 3. Run the experiment

```bash
cd <repo>
sudo bash scripts/run_improved.sh
```

This does a **fixed-total-load peer sweep**: peers {1, 2, 4, 8, 16, 32}, 32 total
iperf3 streams held constant, 5 repeated interleaved runs per cell, 30 s each.
Takes roughly **30–45 min**.

The parent results directory is printed at the start, something like:
```
results/improved_20260603_143200_load32_ecores/
```

At the end it prints the analysis and the plot command.

### Optional: regime test (heavier crypto, forced contention)

```bash
sudo bash scripts/run_improved.sh "16" 32 5 30 40 bottleneck "0 1"
```

This adds a 40 µs artificial decrypt delay and restricts to 2 cores — approaches the
throughput-collapse regime the M1 cannot reach naturally. Needs the `wg_decrypt_delay_us`
knob.

---

## 4. Analyze and plot

```bash
PARENT=results/improved_<stamp>_load32_ecores   # from step 3 output
python3 scripts/analyze_improved.py "$PARENT"   # prints Markdown summary
python3 scripts/plot_improved.py   "$PARENT"    # writes figures/
```

Figures land in `$PARENT/figures/`:

| File | What it shows |
|---|---|
| `eoi_wasted_polls.pdf` | Empty polls/s, stock vs patched, vs peer count — the headline RQ1/RQ3 figure |
| `eoi_total_polls.pdf` | Total NAPI polls/s — what the fix mechanically reduces |
| `eoi_batch_mean.pdf` | Mean `work_done` per delivering poll — the GRO consolidation evidence |
| `eoi_combined.pdf` | All three side by side |

---

## 5. Copy figure into the report

```bash
cp $PARENT/figures/eoi_wasted_polls.pdf report/figures/
# (or eoi_combined.pdf if you prefer the three-panel version)
git add report/figures/eoi_wasted_polls.pdf $PARENT/SUMMARY.md $PARENT/runs_long.csv
git commit -m "Add measured EoI results: improved fixed-load sweep"
git push
```

Then back on macOS, tell Claude to wire it into `report/main.tex` (replace the
illustrative `fig:emptypoll` and update the prose).

---

## What changed vs the May 28 run

| May 28 problem | Fix |
|---|---|
| 4 streams/peer → load grew with peers; 1-peer cell was low-load, not a real control | Total streams held constant; 1-peer runs at full load |
| rmmod/insmod between builds added variance | `wg_eoi_fix` sysfs toggle — same module, same tunnel |
| Single run per cell, no error bars | 5 repeated interleaved runs → median + IQR |
| No batch-size metric | `work_done` histogram → mean batch size per run |
