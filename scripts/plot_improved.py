#!/usr/bin/env python3
"""Render report-ready figures from an improved-sweep SUMMARY.csv.

Reads <parent>/SUMMARY.csv (analyze_improved.py) and writes PDFs into
<parent>/figures/ :
  * eoi_wasted_polls.pdf  — empty (wasted) polls/s, stock vs patched, vs peers
  * eoi_total_polls.pdf   — total polls/s, stock vs patched, vs peers
  * eoi_batch_mean.pdf    — mean delivery batch size (work_done), stock vs patched
  * eoi_combined.pdf      — the three panels side by side (for the report)
Error bars are the IQR (q25..q75) across runs.

Usage: plot_improved.py <parent_dir>
"""
import csv
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

C_STOCK = "#b91c1c"    # red  — baseline / stock
C_PATCH = "#1e3a8a"    # blue — patched (this work)


def load_summary(parent):
    """Return data[metric][fix] = (peers[], median[], lo_err[], hi_err[])."""
    raw = {}
    with open(os.path.join(parent, "SUMMARY.csv")) as fh:
        for r in csv.DictReader(fh):
            key = (r["metric"], int(r["fix"]))
            raw.setdefault(key, []).append(
                (int(r["peers"]), float(r["median"]),
                 float(r["q25"]), float(r["q75"])))
    data = {}
    for (metric, fix), rows in raw.items():
        rows.sort()
        peers = [x[0] for x in rows]
        med = [x[1] for x in rows]
        lo = [x[1] - x[2] for x in rows]
        hi = [x[3] - x[1] for x in rows]
        data.setdefault(metric, {})[fix] = (peers, med, [lo, hi])
    return data


def grouped_bars(ax, data, metric, ylabel, title):
    peers, m0, e0 = data[metric][0]
    _, m1, e1 = data[metric][1]
    x = range(len(peers))
    w = 0.4
    ax.bar([i - w / 2 for i in x], m0, w, yerr=e0, capsize=3,
           color=C_STOCK, label="baseline (stock)")
    ax.bar([i + w / 2 for i in x], m1, w, yerr=e1, capsize=3,
           color=C_PATCH, label="patched (this work)")
    ax.set_xticks(list(x))
    ax.set_xticklabels([str(p) for p in peers])
    ax.set_xlabel("number of peers (total load held constant)")
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.grid(axis="y", alpha=0.3)
    ax.legend(fontsize=8)


def lines(ax, data, metric, ylabel, title):
    peers, m0, e0 = data[metric][0]
    _, m1, e1 = data[metric][1]
    ax.errorbar(peers, m0, yerr=e0, marker="o", color=C_STOCK,
                capsize=3, label="baseline (stock)")
    ax.errorbar(peers, m1, yerr=e1, marker="s", color=C_PATCH,
                capsize=3, label="patched (this work)")
    ax.set_xscale("log", base=2)
    ax.set_xticks(peers)
    ax.set_xticklabels([str(p) for p in peers])
    ax.set_xlabel("number of peers (total load held constant)")
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.grid(alpha=0.3)
    ax.legend(fontsize=8)


def main():
    if len(sys.argv) < 2:
        print("usage: plot_improved.py <parent_dir>", file=sys.stderr)
        sys.exit(1)
    parent = sys.argv[1]
    data = load_summary(parent)
    outdir = os.path.join(parent, "figures")
    os.makedirs(outdir, exist_ok=True)

    specs = [
        ("wasted_s", "empty polls / s", "Empty (wasted) GRO polls", grouped_bars,
         "eoi_wasted_polls.pdf"),
        ("total_s", "total polls / s", "Total NAPI polls", grouped_bars,
         "eoi_total_polls.pdf"),
        ("batch_mean", "mean work_done (packets/poll)",
         "GRO batch size at delivery", lines, "eoi_batch_mean.pdf"),
    ]

    for metric, ylabel, title, fn, name in specs:
        if metric not in data:
            print(f"skip {name}: metric {metric} absent")
            continue
        fig, ax = plt.subplots(figsize=(4.2, 3.0))
        fn(ax, data, metric, ylabel, title)
        fig.tight_layout()
        fig.savefig(os.path.join(outdir, name))
        plt.close(fig)
        print(f"wrote {os.path.join(outdir, name)}")

    # Combined 1x3 panel for the report.
    present = [s for s in specs if s[0] in data]
    if present:
        fig, axes = plt.subplots(1, len(present),
                                 figsize=(4.2 * len(present), 3.0))
        if len(present) == 1:
            axes = [axes]
        for ax, (metric, ylabel, title, fn, _) in zip(axes, present):
            fn(ax, data, metric, ylabel, title)
        fig.tight_layout()
        out = os.path.join(outdir, "eoi_combined.pdf")
        fig.savefig(out)
        plt.close(fig)
        print(f"wrote {out}")

    print(f"\nfigures in {outdir}")
    print("copy the chosen one into report/figures/ and \\includegraphics it.")


if __name__ == "__main__":
    main()
