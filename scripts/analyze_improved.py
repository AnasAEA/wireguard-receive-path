#!/usr/bin/env python3
"""Aggregate an improved-sweep parent dir (run_improved.sh) into plot-ready data.

Reads MANIFEST.csv (peers,total_streams,per_client,delay_us,fix,run,rdir) and,
for every run directory, extracts:
  * throughput  — sum of end.sum_received bits/s over client JSONs   (analyze_runs)
  * GRO         — per-second wasted / useful / total polls, NET_RX softirq ms/s
  * batch_mean  — mean work_done (delivery batch size) from the bpftrace @batch
                  histogram; this is the direct evidence of GRO consolidation
  * latency     — p50 / p99 / p99.9 / max from the ping log

Writes, next to the manifest:
  * runs_long.csv  — one row per run, all metrics (for re-analysis / pandas)
  * SUMMARY.csv    — median + IQR per (peers, fix, metric) for plotting
and prints a Markdown summary (stock vs patched per peer, with deltas) on stdout.

Usage: analyze_improved.py <parent_dir>
"""
import csv
import glob
import os
import re
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from analyze_runs import throughput_gbps, gro_stats, latencies_ms, pct  # noqa: E402

# Metrics carried through to the wide summary / plots.
METRICS = ["tput_gbps", "wasted_s", "useful_s", "total_s", "ratio_pct",
           "netrx_ms_s", "batch_mean", "p50_ms", "p99_ms", "p999_ms", "max_ms"]


def batch_mean(run_dir):
    """Mean work_done from the bpftrace lhist '@batch' block.

    Lines look like:  [4, 8)   12345 |@@@@@@@@        |
    Open overflow bucket:  [64, ...)  678 |@   |
    We weight each bucket by its midpoint (open bucket -> lo + step/2).
    """
    path = os.path.join(run_dir, "bpftrace_raw.txt")
    try:
        with open(path) as fh:
            text = fh.read()
    except FileNotFoundError:
        return float("nan")
    if "@batch" not in text:
        return float("nan")
    block = text.split("@batch", 1)[1]
    num, den = 0.0, 0.0
    for m in re.finditer(r"\[(\d+),\s*(\d+|\.\.\.)\)\s+(\d+)", block):
        lo = int(m.group(1))
        hi = m.group(2)
        count = int(m.group(3))
        if hi == "...":
            mid = lo + 2          # lhist step is 4; nominal midpoint of overflow
        else:
            mid = (lo + int(hi)) / 2.0
        num += mid * count
        den += count
    return num / den if den else float("nan")


def run_metrics(run_dir):
    t = throughput_gbps(run_dir)
    w, u, tot, ms = gro_stats(run_dir)
    ratio = 100.0 * w / tot if tot else float("nan")
    bm = batch_mean(run_dir)
    lat = sorted(latencies_ms(run_dir))
    return {
        "tput_gbps": t, "wasted_s": w, "useful_s": u, "total_s": tot,
        "ratio_pct": ratio, "netrx_ms_s": ms, "batch_mean": bm,
        "p50_ms": pct(lat, 50), "p99_ms": pct(lat, 99),
        "p999_ms": pct(lat, 99.9), "max_ms": lat[-1] if lat else float("nan"),
    }


def read_manifest(parent):
    rows = []
    with open(os.path.join(parent, "MANIFEST.csv")) as fh:
        for r in csv.DictReader(fh):
            r["peers"] = int(r["peers"])
            r["fix"] = int(r["fix"])
            r["run"] = int(r["run"])
            rows.append(r)
    return rows


def med(xs):
    xs = [x for x in xs if x == x]  # drop NaN
    return statistics.median(xs) if xs else float("nan")


def q(xs, p):
    xs = sorted(x for x in xs if x == x)
    return pct(xs, p) if xs else float("nan")


def delta_pct(patched, stock):
    return 100.0 * (patched - stock) / stock if stock else float("nan")


def main():
    if len(sys.argv) < 2:
        print("usage: analyze_improved.py <parent_dir>", file=sys.stderr)
        sys.exit(1)
    parent = sys.argv[1]
    rows = read_manifest(parent)

    # Per-run long table.
    long_path = os.path.join(parent, "runs_long.csv")
    with open(long_path, "w", newline="") as fh:
        wtr = csv.writer(fh)
        wtr.writerow(["peers", "total_streams", "per_client", "delay_us",
                      "fix", "run"] + METRICS)
        for r in rows:
            m = run_metrics(r["rdir"])
            wtr.writerow([r["peers"], r["total_streams"], r["per_client"],
                          r["delay_us"], r["fix"], r["run"]]
                         + [f"{m[k]:.4f}" for k in METRICS])

    # Group by (peers, fix).
    groups = {}
    for r in rows:
        groups.setdefault((r["peers"], r["fix"]), []).append(run_metrics(r["rdir"]))

    peers_list = sorted({p for (p, _) in groups})

    # Wide summary CSV (median + IQR per metric).
    sum_path = os.path.join(parent, "SUMMARY.csv")
    with open(sum_path, "w", newline="") as fh:
        wtr = csv.writer(fh)
        wtr.writerow(["peers", "fix", "metric", "median", "q25", "q75", "n"])
        for p in peers_list:
            for fix in (0, 1):
                g = groups.get((p, fix), [])
                for metric in METRICS:
                    vals = [x[metric] for x in g]
                    wtr.writerow([p, fix, metric, f"{med(vals):.4f}",
                                  f"{q(vals, 25):.4f}", f"{q(vals, 75):.4f}",
                                  len([v for v in vals if v == v])])

    # Markdown report.
    delay = rows[0]["delay_us"] if rows else "0"
    total_streams = rows[0]["total_streams"] if rows else "?"
    print("# Improved sweep summary\n")
    print(f"- parent: `{os.path.basename(parent)}`")
    print(f"- total offered streams (held constant): **{total_streams}**")
    print(f"- decrypt delay: **{delay} us**")
    print(f"- runs per (peers, build): {max((r['run'] for r in rows), default=0)}\n")

    def line(p, fix, keys):
        g = groups.get((p, fix), [])
        return [med([x[k] for x in g]) for k in keys]

    print("## GRO scheduling — median per second (fixed total load)\n")
    print("| peers | s/peer | build | total/s | wasted/s | useful/s | waste% | batch | Δtotal | Δwasted |")
    print("|--:|--:|---|--:|--:|--:|--:|--:|--:|--:|")
    for p in peers_list:
        spc = next((r["per_client"] for r in rows if r["peers"] == p), "?")
        st = line(p, 0, ["total_s", "wasted_s", "useful_s", "ratio_pct", "batch_mean"])
        pa = line(p, 1, ["total_s", "wasted_s", "useful_s", "ratio_pct", "batch_mean"])
        print(f"| {p} | {spc} | stock   | {st[0]:,.0f} | {st[1]:,.0f} | {st[2]:,.0f} | {st[3]:.1f} | {st[4]:.1f} | | |")
        print(f"| {p} | {spc} | patched | {pa[0]:,.0f} | {pa[1]:,.0f} | {pa[2]:,.0f} | {pa[3]:.1f} | {pa[4]:.1f} | "
              f"{delta_pct(pa[0], st[0]):+.1f}% | {delta_pct(pa[1], st[1]):+.1f}% |")

    print("\n## Throughput & latency — median (fixed total load)\n")
    print("| peers | build | Gbps | p50 ms | p99 ms | p99.9 ms | max ms |")
    print("|--:|---|--:|--:|--:|--:|--:|")
    for p in peers_list:
        st = line(p, 0, ["tput_gbps", "p50_ms", "p99_ms", "p999_ms", "max_ms"])
        pa = line(p, 1, ["tput_gbps", "p50_ms", "p99_ms", "p999_ms", "max_ms"])
        print(f"| {p} | stock   | {st[0]:.2f} | {st[1]:.3f} | {st[2]:.3f} | {st[3]:.3f} | {st[4]:.3f} |")
        print(f"| {p} | patched | {pa[0]:.2f} | {pa[1]:.3f} | {pa[2]:.3f} | {pa[3]:.3f} | {pa[4]:.3f} |")

    print(f"\n- wrote `{os.path.basename(long_path)}`, `{os.path.basename(sum_path)}`")
    print(f"- plot: `python3 scripts/plot_improved.py {parent}`")


if __name__ == "__main__":
    main()
