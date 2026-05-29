# Running the Hardened Experiments (v2)

**Target:** Fedora Asahi Remix, Apple M1 Pro, bureau 225.
**Goal:** turn the May 28 first-pass findings into report-grade results by attacking
the three weaknesses identified in review — uncontrolled variance, proxy-only
metrics, and the unreachable saturation regime.

This guide is self-contained: follow it top to bottom. It assumes the May 28
infrastructure is already in place (patched module built, multipeer keys present).
If starting from a clean machine, do `admin/COMPILATION_AND_TEST_GUIDE.md` first.

---

## 0. The three levers

| Lever | Weakness it fixes | Script |
|---|---|---|
| 1. Variance control + statistics | Run-to-run noise, only 1–3 runs | `run_repeated.sh` |
| 2. Direct mechanism metrics | GRO poll count is a proxy | built into `measure_multipeer_v2.sh` |
| 3. Bottleneck induction | Loopback never saturates | `run_delay_sweep.sh` + delay patch |

Run them in order. Lever 1 gives clean baselines; lever 3 is the one that can
produce a headline result (a local reproduction of the paper's throughput effect).

---

## 1. Pull the harness

```bash
cd ~/Documents/internship/Io-uring-Internship   # adjust to your clone path
git pull
chmod +x scripts/*.sh scripts/*.py
ls scripts/tuning.sh scripts/measure_multipeer_v2.sh scripts/run_repeated.sh \
   scripts/analyze_runs.py scripts/analyze_one.py scripts/run_delay_sweep.sh
```

Quick dependency check:

```bash
which iperf3 bpftrace python3 column
sudo bpftrace -l 'tracepoint:irq:softirq_*'   # confirm softirq_entry/exit exist
```

If `tracepoint:irq:softirq_entry` is missing, the NET_RX-time metric won't record
(everything else still works — the GRO counts and histogram are kprobe-based).

---

## 2. Confirm both modules are available

```bash
# Stock comes from the distro:
modinfo wireguard | grep filename

# Patched .ko from the May 28 build:
ls linux/drivers/net/wireguard/wireguard.ko
modinfo linux/drivers/net/wireguard/wireguard.ko | grep vermagic
uname -r          # vermagic must match exactly
```

`load_stock.sh` / `load_patched.sh` switch between them. `run_repeated.sh` calls
these for you.

---

## 3. Lever 1 — Variance control + statistics

**What changes vs May 28:** efficiency cores are offlined (removes the biggest
variance source on the M1), the cpufreq governor is locked to `performance`,
iperf3 omits a 5 s warm-up, runs are 60 s, and each module is run **10 times** so
`analyze_runs.py` can report a median and standard deviation instead of a single
noisy number.

```bash
# 32 peers, 10 runs each module, 60 s per run.
sudo bash scripts/run_repeated.sh 32 10 60
```

Arguments: `run_repeated.sh [N] [RUNS] [DURATION] [MODE] [KEEP_CPUS]`
(MODE defaults to `ecores`; see §5 for the `bottleneck` mode.)

Output lands in `results/repeated_<stamp>_mp32_ecores/`:

```
run01_stock/  run01_patched/  ...  run10_stock/  run10_patched/
SUMMARY.md     ← median/min/max/stdev throughput, GRO deltas, p50/p99/p99.9 latency
```

**Read `SUMMARY.md`.** The decisive questions it answers:

- Is the 32-peer throughput truly flat, with the stdev to prove it?
- Does the GRO suppression (−14–20%) survive variance control?
- What are the real latency tails (p99/p99.9), not just min/avg/max?

Repeat at other peer counts to re-test the May 28 trend and the suspected
regression:

```bash
sudo bash scripts/run_repeated.sh 16 10 60
sudo bash scripts/run_repeated.sh 48 10 60   # ← settles the −7.7% question with stats
```

> **The 48-peer run is the important one.** If patched stays within one stdev of
> stock across 10 runs, the May 28 "regression" was noise. If it is consistently
> below, it is real and must be reported honestly.

---

## 4. Lever 2 — Direct mechanism metrics

No separate command — `measure_multipeer_v2.sh` (invoked by every runner above)
already records them. Per run directory:

| File | Metric |
|---|---|
| `bpftrace_raw.txt` | per-second `GRO <wasted> <useful> NETRX_NS <ns>` lines, then a `@batch` histogram of work_done at the end |
| `softirqs_before.txt` / `softirqs_after.txt` | `/proc/softirqs` NET_RX counters (cheap cross-check) |
| `ping_latency.txt` | every per-packet RTT (for percentiles) |

To eyeball the **NET_RX softirq time** and **delivery batch-size histogram** for a
single run:

```bash
RUN=results/repeated_<stamp>_mp32_ecores/run01_patched
tail -20 "$RUN/bpftrace_raw.txt"     # the @batch histogram (queue depth at delivery)
python3 scripts/analyze_one.py "$RUN"  # one-line CSV incl. netrx_ms_s
```

**Why these matter for the report:** NET_RX softirq time is the *actual* quantity
the paper says collapses throughput — measuring it directly (not via poll counts)
closes the "you only measured a proxy" gap. The work_done histogram shows whether
the patch changes how packets batch on delivery (deeper batches = the queue was
allowed to fill before GRO ran).

---

## 5. Lever 3 — Bottleneck induction (the headline experiment)

The M1's NEON ChaCha20 is too fast for decryption to ever bottleneck on loopback,
so the EoI feedback loop never engages. This lever **adds a controlled per-packet
decrypt cost** and sweeps it to find the threshold where EoI starts to hurt
throughput — substituting for the real-NIC saturation we can't reach.

### 5.1 Build the delay-capable module (one time)

Follow `admin/PATCH_DECRYPT_DELAY.md` to apply the diff (it replaces the plain
conditional with two runtime knobs), then rebuild:

```bash
make -C /lib/modules/$(uname -r)/build \
    M=$PWD/linux/drivers/net/wireguard
sudo modprobe udp_tunnel ip6_udp_tunnel libcurve25519
sudo rmmod wireguard 2>/dev/null
sudo insmod linux/drivers/net/wireguard/wireguard.ko

# Verify the knobs exist:
cat /sys/module/wireguard/parameters/wg_eoi_fix           # 1
cat /sys/module/wireguard/parameters/wg_decrypt_delay_us  # 0
```

### 5.2 Run the sweep

```bash
# 16 peers, 30 s per cell, WG confined to CPUs 0+1, default delays 0..80 us.
sudo bash scripts/run_delay_sweep.sh 16 30 "0 1"
```

Arguments: `run_delay_sweep.sh [N] [DURATION] [KEEP_CPUS] [DELAYS]`.
To sweep finer near a crossover, e.g.: `... "0 1" "0 10 15 20 25 30 40"`.

The runner keeps one tunnel up and toggles `wg_decrypt_delay_us` and `wg_eoi_fix`
via sysfs between cells (no reloads). Output:

```
results/sweep_<stamp>_mp16/
  d000_fix0/ d000_fix1/ d005_fix0/ ...   ← one dir per cell
  SWEEP.csv   ← delay_us,fix,tput_gbps,wasted_s,useful_s,total_s,netrx_ms_s,p50_ms,p99_ms,p999_ms,max_ms
```

### 5.3 Read the result

`fix=0` is stock behavior, `fix=1` is André's fix, at the same decrypt cost.

```bash
column -t -s, results/sweep_<stamp>_mp16/SWEEP.csv
```

**What you're looking for:** the delay D\* where the `fix=0` throughput column
starts dropping while `fix=1` holds.

- **Crossover exists** → you have a local reproduction of the paper's effect. The
  fix recovers throughput once decryption is the bottleneck. This is the strongest
  possible result without a real NIC — report the crossover delay and the
  throughput gap.
- **They track together at all delays** → also a finding: on this architecture EoI
  overhead is dominated by other costs, and the fix's value is in latency tails
  (lever 1), not throughput. Report that honestly.

---

## 6. After the runs — restore the machine

The runners restore cores/governor on exit via a trap, but if a run was killed
mid-way, restore manually:

```bash
source scripts/tuning.sh
tuning_restore                 # all cores back online, dynamic governor
echo 0 | sudo tee /sys/module/wireguard/parameters/wg_decrypt_delay_us
echo 1 | sudo tee /sys/module/wireguard/parameters/wg_eoi_fix
sudo bash scripts/teardown_multipeer.sh 64   # safe even if fewer peers were up
nproc                          # confirm all cores online again
```

---

## 7. Get the data off the machine

`results/` is gitignored, so nothing here syncs by default. Back up at least the
small text summaries so a reinstall can't wipe them:

```bash
# Commit just the lightweight summaries (not the bulky iperf3 JSON):
git add -f results/**/SUMMARY.md results/**/SWEEP.csv \
            results/**/info.txt results/**/bpftrace_raw.txt \
            results/**/ping_latency.txt
git commit -m "Add v2 experiment summaries (variance-controlled + delay sweep)"
git push
```

(Or copy the whole `results/` tree to the Mac via `scp`/USB if you want the JSON too.)

---

## 8. What each result feeds in the report

| Result | Report section |
|---|---|
| `run_repeated.sh` SUMMARY (median ± stdev, p99/p99.9) | Evaluation — replaces the noisy single-run tables |
| NET_RX softirq time, work_done histogram | Evaluation — direct mechanism evidence |
| 48-peer statistical verdict | Evaluation / Limitations — confirm or retract the regression |
| `SWEEP.csv` crossover | Evaluation — the closest thing to reproducing the paper |
| "no crossover" (if that's the outcome) | Limitations — architecture-dependence (the ARM/NEON answer to the reviewer) |
