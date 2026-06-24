#!/usr/bin/env python3
"""Summarize a run_sweep.sh CSV: median / IQR / CV per (module, peers), plus the
patched-stock deltas. Low CV (< ~5%) => the run count is enough; high CV => add runs."""
import sys, csv, statistics as st
from collections import defaultdict

path = sys.argv[1] if len(sys.argv) > 1 else "sweep.csv"
g = defaultdict(lambda: defaultdict(list))
with open(path) as f:
    for row in csv.DictReader(f):
        try:
            k = (row["module"], int(row["peers"]))
        except Exception:
            continue
        for m in ("gbps", "wasted_frac"):
            try:
                g[k][m].append(float(row[m]))
            except Exception:
                pass

def stats(xs):
    if not xs:
        return float("nan"), float("nan"), float("nan"), 0
    md = st.median(xs)
    if len(xs) >= 2:
        q = st.quantiles(xs, n=4)
        iqr = q[2] - q[0]
        cv = st.pstdev(xs) / st.mean(xs) * 100 if st.mean(xs) else float("nan")
    else:
        iqr, cv = 0.0, 0.0
    return md, iqr, cv, len(xs)

print(f"{'mod':8}{'peers':>6}{'n':>4}{'gbps_med':>10}{'gbps_cv%':>9}"
      f"{'wfrac_med':>11}{'wfrac_cv%':>10}")
for k in sorted(g, key=lambda x: (x[1], x[0])):
    gm, gi, gc, n = stats(g[k]["gbps"])
    wm, wi, wc, _ = stats(g[k]["wasted_frac"])
    print(f"{k[0]:8}{k[1]:>6}{n:>4}{gm:>10.3f}{gc:>9.1f}{wm:>11.4f}{wc:>10.1f}")

print("\n-- median(patched) - median(stock) --")
for N in sorted({k[1] for k in g}):
    s, p = g.get(("stock", N), {}), g.get(("patched", N), {})
    if s.get("gbps") and p.get("gbps"):
        dg = st.median(p["gbps"]) - st.median(s["gbps"])
        dw = st.median(p["wasted_frac"]) - st.median(s["wasted_frac"])
        print(f"peers={N:>3}: dGbps={dg:+.3f}  dWastedFrac={dw:+.4f}")
