#!/usr/bin/env python3
"""Analyze a Phase B decrypt-cost sweep (measure_decrypt_sweep.sh output, 2026-07-02 schema).
  analyze_decsweep.py data/cloudlab/decsweep_<ts>.csv [OUTDIR]
Per (delay x condition): median/IQR of wasted%, CPU CE (3 lenses), p50/p99/p999, actual
load, retransmits; off-vs-both deltas. Emits fig_decsweep_wasted.png (the headline: waste
removal grows with decrypt cost) and fig_decsweep_cpu.png. Only status=ok rows are used.
Stdlib + matplotlib only.
"""
import csv, sys, statistics as st
from collections import defaultdict

PATH = sys.argv[1] if len(sys.argv) > 1 else "data/cloudlab/decsweep_20260706_0321.csv"
OUT  = sys.argv[2] if len(sys.argv) > 2 else "docs/meetings/figures"

rows = [r for r in csv.DictReader(open(PATH))]
kept = [r for r in rows if r.get("status") == "ok"]
print(f"loaded {len(rows)} rows, {len(rows)-len(kept)} non-ok dropped\n")

g = defaultdict(list)
for r in kept:
    g[(int(r["delay_ns"]), r["condition"])].append(r)
delays = sorted({d for d, _ in g})

def med(k, key): return st.median(float(r[key]) for r in g[k])
def quart(k, key):
    v = sorted(float(r[key]) for r in g[k]); n = len(v)
    return v[n // 4], v[(3 * n) // 4]

hdr = f"{'delay_ns':>8} {'cond':>4} {'n':>2} {'wasted%':>8} {'IQR':>13} {'soft_ce':>7} {'busy_ce':>7} {'p99_us':>7} {'act_gbps':>8} {'rtx':>5}"
print(hdr); print("-" * len(hdr))
for d in delays:
    for c in ("off", "both"):
        k = (d, c)
        lo, hi = quart(k, "wasted_frac")
        print(f"{d:>8} {c:>4} {len(g[k]):>2} {med(k,'wasted_frac')*100:>7.1f}% "
              f"{lo*100:>5.1f}-{hi*100:>5.1f}% {med(k,'softirq_ce'):>7.3f} "
              f"{med(k,'total_busy_ce'):>7.2f} {med(k,'p99_us'):>7.1f} "
              f"{med(k,'load_actual_gbps'):>8.3f} {med(k,'retransmits'):>5.0f}")
    for key, lbl in (("softirq_ce", "soft_ce"), ("total_busy_ce", "busy_ce"), ("p99_us", "p99")):
        do, db = med((d, "off"), key), med((d, "both"), key)
        print(f"          -> {lbl}: off {do:.3f} vs both {db:.3f}  delta {100*(db-do)/do:+.1f}%")
    print()

print("waste removed by the fix (off wasted% - both wasted%), per delay:")
for d in delays:
    wo, wb = med((d, "off"), "wasted_frac"), med((d, "both"), "wasted_frac")
    print(f"  {d/1000:>4.0f} us: {wo*100:.1f}% -> {wb*100:.1f}%   removes {100*(wo-wb)/wo:.0f}% of the waste")

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

xs = [d / 1000 for d in delays]
fig, ax = plt.subplots(figsize=(6.5, 4.2))
for c, col in (("off", "#c0392b"), ("both", "#2471a3")):
    ys  = [med((d, c), "wasted_frac") * 100 for d in delays]
    los = [quart((d, c), "wasted_frac")[0] * 100 for d in delays]
    his = [quart((d, c), "wasted_frac")[1] * 100 for d in delays]
    ax.plot(xs, ys, "o-", color=col, label=c)
    ax.fill_between(xs, los, his, color=col, alpha=0.18)
ax.set_xlabel("injected decrypt delay (µs/packet)")
ax.set_ylabel("wasted polls (% of all polls)")
ax.set_title("Fix efficacy grows with decrypt cost (capped 2 Gb/s, 8 peers, 5 reps)")
ax.set_ylim(0, 40); ax.legend(); ax.grid(alpha=0.3)
fig.tight_layout(); fig.savefig(f"{OUT}/fig_decsweep_wasted.png", dpi=130)
print(f"\nwrote {OUT}/fig_decsweep_wasted.png")

fig, axes = plt.subplots(1, 2, figsize=(10, 4.2))
for ax, key, lbl in ((axes[0], "softirq_ce", "softirq (cores-equiv)"),
                     (axes[1], "total_busy_ce", "total busy (cores-equiv)")):
    for c, col in (("off", "#c0392b"), ("both", "#2471a3")):
        ys  = [med((d, c), key) for d in delays]
        los = [quart((d, c), key)[0] for d in delays]
        his = [quart((d, c), key)[1] for d in delays]
        ax.plot(xs, ys, "o-", color=col, label=c)
        ax.fill_between(xs, los, his, color=col, alpha=0.18)
    ax.set_xlabel("injected decrypt delay (µs/packet)")
    ax.set_ylabel(lbl); ax.legend(); ax.grid(alpha=0.3)
axes[0].set_title("CPU: softirq lens"); axes[1].set_title("CPU: total busy lens")
fig.tight_layout(); fig.savefig(f"{OUT}/fig_decsweep_cpu.png", dpi=130)
print(f"wrote {OUT}/fig_decsweep_cpu.png")
