#!/usr/bin/env python3
"""Aggregate repeated stock-vs-patched runs into medians + latency percentiles.

Reads a parent directory produced by run_repeated.sh containing subdirectories
named runNN_stock / runNN_patched. Emits a Markdown summary on stdout.

Per run it extracts:
  * throughput   — sum of end.sum_received.bits_per_second over all client JSONs
  * GRO          — per-second wasted / useful / NET_RX softirq ns from bpftrace,
                   dropping the first WARMUP and last second to match the
                   iperf3 warm-up omission
  * latency      — every per-packet RTT parsed from the ping log

Across runs it reports, per module:
  * throughput: median / min / max / stdev (one sample per run)
  * GRO: mean per-second wasted, useful, total, NET_RX softirq ms/s
  * latency: pooled p50 / p99 / p99.9 / max over all packets from all runs

Usage: analyze_runs.py <parent_dir> [duration_s]
"""
import glob
import json
import os
import re
import statistics
import sys

WARMUP = 5  # seconds dropped from the head of each bpftrace stream


def throughput_gbps(run_dir):
    total = 0.0
    for f in glob.glob(os.path.join(run_dir, "iperf3_client_*.json")):
        try:
            with open(f) as fh:
                d = json.load(fh)
            total += d["end"]["sum_received"]["bits_per_second"]
        except Exception:
            pass
    return total / 1e9


def gro_stats(run_dir):
    """Return (wasted_per_s, useful_per_s, total_per_s, netrx_ms_per_s)."""
    path = os.path.join(run_dir, "bpftrace_raw.txt")
    rows = []
    try:
        with open(path) as fh:
            for line in fh:
                m = re.match(r"GRO\s+(\d+)\s+(\d+)\s+NETRX_NS\s+(\d+)", line)
                if m:
                    rows.append(tuple(int(x) for x in m.groups()))
    except FileNotFoundError:
        return (0.0, 0.0, 0.0, 0.0)
    # Drop warm-up head and the final (possibly partial) second.
    rows = rows[WARMUP:-1] if len(rows) > WARMUP + 1 else rows
    if not rows:
        return (0.0, 0.0, 0.0, 0.0)
    n = len(rows)
    w = sum(r[0] for r in rows) / n
    u = sum(r[1] for r in rows) / n
    ns = sum(r[2] for r in rows) / n
    return (w, u, w + u, ns / 1e6)  # ns/s -> ms/s


def latencies_ms(run_dir):
    path = os.path.join(run_dir, "ping_latency.txt")
    out = []
    try:
        with open(path) as fh:
            for line in fh:
                m = re.search(r"time=([\d.]+)\s*ms", line)
                if m:
                    out.append(float(m.group(1)))
    except FileNotFoundError:
        pass
    return out


def pct(sorted_vals, p):
    if not sorted_vals:
        return float("nan")
    k = (len(sorted_vals) - 1) * (p / 100.0)
    lo = int(k)
    hi = min(lo + 1, len(sorted_vals) - 1)
    return sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * (k - lo)


def collect(parent, module):
    runs = sorted(glob.glob(os.path.join(parent, f"run*_{module}")))
    tput, wasted, useful, total, netrx, lat = [], [], [], [], [], []
    for r in runs:
        tput.append(throughput_gbps(r))
        w, u, t, ms = gro_stats(r)
        wasted.append(w); useful.append(u); total.append(t); netrx.append(ms)
        lat.extend(latencies_ms(r))
    return {
        "n_runs": len(runs),
        "tput": tput,
        "wasted": wasted, "useful": useful, "total": total, "netrx": netrx,
        "lat": sorted(lat),
    }


def med(xs):
    return statistics.median(xs) if xs else float("nan")


def mean(xs):
    return statistics.fmean(xs) if xs else float("nan")


def stdev(xs):
    return statistics.pstdev(xs) if len(xs) > 1 else 0.0


def delta_pct(patched, stock):
    if stock == 0:
        return float("nan")
    return 100.0 * (patched - stock) / stock


def main():
    if len(sys.argv) < 2:
        print("usage: analyze_runs.py <parent_dir> [duration_s]", file=sys.stderr)
        sys.exit(1)
    parent = sys.argv[1]
    s = collect(parent, "stock")
    p = collect(parent, "patched")

    print(f"# Repeated-run summary\n")
    print(f"- parent: `{os.path.basename(parent)}`")
    print(f"- runs per module: stock={s['n_runs']}, patched={p['n_runs']}")
    print(f"- latency samples pooled: stock={len(s['lat'])}, patched={len(p['lat'])}\n")

    print("## Throughput (Gbps, across runs)\n")
    print("| Module | median | min | max | stdev |")
    print("|---|---|---|---|---|")
    print(f"| Stock   | {med(s['tput']):.3f} | {min(s['tput'] or [0]):.3f} | {max(s['tput'] or [0]):.3f} | {stdev(s['tput']):.3f} |")
    print(f"| Patched | {med(p['tput']):.3f} | {min(p['tput'] or [0]):.3f} | {max(p['tput'] or [0]):.3f} | {stdev(p['tput']):.3f} |")
    print(f"\n**Δ median throughput (patched vs stock): {delta_pct(med(p['tput']), med(s['tput'])):+.1f}%**\n")

    print("## GRO scheduling (per-second means)\n")
    print("| Module | wasted/s | useful/s | total/s | NET_RX softirq ms/s |")
    print("|---|---|---|---|---|")
    print(f"| Stock   | {mean(s['wasted']):,.0f} | {mean(s['useful']):,.0f} | {mean(s['total']):,.0f} | {mean(s['netrx']):.1f} |")
    print(f"| Patched | {mean(p['wasted']):,.0f} | {mean(p['useful']):,.0f} | {mean(p['total']):,.0f} | {mean(p['netrx']):.1f} |")
    print(f"\n- Δ total GRO/s: {delta_pct(mean(p['total']), mean(s['total'])):+.1f}%")
    print(f"- Δ wasted GRO/s: {delta_pct(mean(p['wasted']), mean(s['wasted'])):+.1f}%")
    print(f"- Δ NET_RX softirq time: {delta_pct(mean(p['netrx']), mean(s['netrx'])):+.1f}%\n")

    print("## Latency (ms, pooled across runs)\n")
    print("| Module | p50 | p99 | p99.9 | max |")
    print("|---|---|---|---|---|")
    print(f"| Stock   | {pct(s['lat'],50):.3f} | {pct(s['lat'],99):.3f} | {pct(s['lat'],99.9):.3f} | {(s['lat'][-1] if s['lat'] else float('nan')):.3f} |")
    print(f"| Patched | {pct(p['lat'],50):.3f} | {pct(p['lat'],99):.3f} | {pct(p['lat'],99.9):.3f} | {(p['lat'][-1] if p['lat'] else float('nan')):.3f} |")
    print(f"\n- Δ p99 latency: {delta_pct(pct(p['lat'],99), pct(s['lat'],99)):+.1f}%")
    print(f"- Δ p99.9 latency: {delta_pct(pct(p['lat'],99.9), pct(s['lat'],99.9)):+.1f}%")


if __name__ == "__main__":
    main()
