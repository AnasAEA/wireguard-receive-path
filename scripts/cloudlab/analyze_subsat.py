#!/usr/bin/env python3
"""Analyze a Phase A sub-saturation campaign (measure_subsat.sh output).
  analyze_subsat.py data/cloudlab/subsat_<ts>.csv [OUTDIR]
Prints: fairness (off vs both actual load, delta Gb/s AND delta%), per-load median/IQR of
softirq/system/total CPU-CE + p99/p999, and off-vs-both deltas with an (approx) Mann-Whitney
p. Emits fig_subsat_cpu.png and fig_subsat_latency.png. Stdlib + matplotlib only.
"""
import csv, sys, math, statistics as st
from collections import defaultdict

PATH = sys.argv[1] if len(sys.argv) > 1 else "data/cloudlab/subsat_20260701_0609.csv"
OUT  = sys.argv[2] if len(sys.argv) > 2 else "docs/meetings/figures"
LOAD, ACT, COND = "load_target_gbps", "load_actual_gbps", "condition"
METRICS = ["softirq_ce", "system_ce", "total_busy_ce", "p99_us", "p999_us"]

rows = [r for r in csv.DictReader(open(PATH))]
kept = [r for r in rows if "REJECT" not in r.get("notes", "")]
print(f"loaded {len(rows)} rows, {len(rows)-len(kept)} REJECT-tagged dropped\n")

def fnum(x):
    try: return float(x)
    except Exception: return None

g = defaultdict(lambda: defaultdict(list))
for r in kept:
    g[r[LOAD]][r[COND]].append(r)
loads = sorted(g, key=float)

def col(rlist, key): return [v for v in (fnum(r[key]) for r in rlist) if v is not None]
def q(xs, p):
    xs = sorted(xs); n = len(xs)
    if n == 1: return xs[0]
    i = p*(n-1); lo = int(i); f = i-lo
    return xs[lo] if lo+1 >= n else xs[lo]*(1-f)+xs[lo+1]*f

def mwu_p(a, b):
    """Two-sided Mann-Whitney U, normal approx w/ continuity (rough at n=8, a guide)."""
    na, nb = len(a), len(b)
    if na < 2 or nb < 2: return float("nan")
    U = sum((x > y) + 0.5*(x == y) for x in a for y in b)
    mu = na*nb/2.0; sd = math.sqrt(na*nb*(na+nb+1)/12.0)
    if sd == 0: return 1.0
    z = (abs(U-mu) - 0.5)/sd
    return max(0.0, min(1.0, 2*(1-0.5*(1+math.erf(z/math.sqrt(2))))))

# --- fairness: off vs both actual load ---
print("=== FAIRNESS: actual load, off vs both ===")
print(f"{'target':>7} {'off_act':>8} {'both_act':>9} {'d_gbps':>8} {'d_pct':>8}")
pooled_actual = {}
for L in loads:
    off, both = col(g[L].get("off", []), ACT), col(g[L].get("both", []), ACT)
    pooled_actual[L] = st.mean(off+both) if (off+both) else 0.0
    if not off or not both: continue
    mo, mb = st.mean(off), st.mean(both); d = mb-mo
    if float(L) == 0:
        print(f"{L:>7} {mo:>8.3f} {mb:>9.3f} {'(0 load: check no bulk)':>17}")
    else:
        pct = 100*d/mo if mo else float('nan')
        flag = "  <-- >10%!" if abs(pct) > 10 else ""
        print(f"{L:>7} {mo:>8.3f} {mb:>9.3f} {d:>+8.3f} {pct:>+7.1f}%{flag}")

# --- per-load metric comparison ---
print("\n=== off vs both per load (median [IQR]) + approx MWU p ===")
for L in loads:
    print(f"\n--- target {L} Gb/s  (actual~{pooled_actual[L]:.2f}) ---")
    off, both = g[L].get("off", []), g[L].get("both", [])
    for m in METRICS:
        xo, xb = col(off, m), col(both, m)
        if len(xo) < 2 or len(xb) < 2: continue
        mo, mb = st.median(xo), st.median(xb)
        d = mb-mo; pct = 100*d/mo if mo else float('nan')
        p = mwu_p(xo, xb)
        io = f"[{q(xo,.25):.3g},{q(xo,.75):.3g}]"; ib = f"[{q(xb,.25):.3g},{q(xb,.75):.3g}]"
        arrow = "both LOWER " if d < 0 else "both higher"
        sig = "*" if p < 0.05 else " "
        print(f"  {m:13s} off={mo:9.3f} {io:18s} both={mb:9.3f} {ib:18s} "
              f"d={d:+9.3f}({pct:+6.1f}%) {arrow} p~{p:.3f}{sig}")

# --- figures ---
try:
    import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
    COL = {"off": "#9aa0a6", "both": "#34a853"}
    def plot(metrics, ylabel, title, fname):
        plt.figure(figsize=(7, 4.6))
        for cond in ("off", "both"):
            for m, ls in zip(metrics, ("-", "--")):
                xs, ys, elo, ehi = [], [], [], []
                for L in loads:
                    v = col(g[L].get(cond, []), m)
                    if not v: continue
                    md = st.median(v)
                    xs.append(pooled_actual[L]); ys.append(md)
                    elo.append(md-q(v,.25)); ehi.append(q(v,.75)-md)
                lab = f"{cond} · {m}" if len(metrics) > 1 else cond
                plt.errorbar(xs, ys, yerr=[elo, ehi], marker="o", ls=ls,
                             color=COL[cond], capsize=3, lw=1.8, label=lab)
        plt.xlabel("actual bulk load (Gb/s)"); plt.ylabel(ylabel)
        plt.title(title); plt.grid(True, alpha=0.3); plt.legend(fontsize=8)
        plt.tight_layout(); plt.savefig(f"{OUT}/{fname}", dpi=130); plt.close()
        print(f"  wrote {OUT}/{fname}")
    print("\n=== figures ===")
    plot(["softirq_ce", "system_ce"], "CPU cores-equivalent",
         "Receive CPU vs load — off vs both (median, IQR bars)", "fig_subsat_cpu.png")
    plot(["p99_us", "p999_us"], "round-trip latency (µs)",
         "Tail latency vs load — off vs both (median, IQR bars)", "fig_subsat_latency.png")
except Exception as e:
    print(f"[plot skipped: {e}]")
