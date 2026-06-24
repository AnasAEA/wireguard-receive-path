#!/usr/bin/env python3
"""Plot the consolidated CloudLab results for the report.
  plot_results.py all_<ts>.csv cpu_<ts>.txt OUTDIR
Produces (French labels, for the supervisor note):
  fig_wasted_vs_debit.png  -- wasted-poll fraction AND throughput per condition
  fig_cpu_coeurs.png       -- per-core busy% under stock (the single saturated core)
"""
import sys, csv, statistics as st
from collections import defaultdict
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

csv_path, cpu_path, outdir = sys.argv[1], sys.argv[2], sys.argv[3]

ORDER = ["stock", "move", "batch", "root"]
LABEL = {"stock": "Stock\n(rien)", "move": "Patch\ndéplacé",
         "batch": "Attente\nactive", "root": "Réveil\ntête prête"}
COLOR = {"stock": "#9aa0a6", "move": "#4285f4", "batch": "#fbbc04", "root": "#34a853"}

g = defaultdict(lambda: defaultdict(list))
for r in csv.DictReader(open(csv_path)):
    c = r["cond"]
    try: g[c]["wf"].append(float(r["wasted_frac"]))
    except: pass
    try:
        gb = float(r["gbps"])
        if gb > 0: g[c]["gb"].append(gb)   # drop stalled (0/NA) throughput reps
    except: pass

conds = [c for c in ORDER if c in g]
wf = [st.median(g[c]["wf"]) * 100 for c in conds]          # wasted-poll %
gb = [st.median(g[c]["gb"]) if g[c]["gb"] else 0 for c in conds]
nrep = {c: len(g[c]["wf"]) for c in conds}
stalls = {c: nrep[c] - len(g[c]["gb"]) for c in conds}
cols = [COLOR[c] for c in conds]
labs = [LABEL[c] for c in conds]

# ---- Figure 1: wasted-poll fraction (drops) next to throughput (flat) ----
fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(10, 4.2))

b1 = ax1.bar(labs, wf, color=cols, edgecolor="black", linewidth=0.6)
ax1.set_ylabel("Polls gaspillés (%)")
ax1.set_title("Ce qu'on sait réduire :\nla fraction de polls gaspillés")
ax1.set_ylim(0, max(wf) * 1.25)
for r, v in zip(b1, wf):
    ax1.text(r.get_x()+r.get_width()/2, v+0.6, f"{v:.0f}%", ha="center", fontweight="bold")

b2 = ax2.bar(labs, gb, color=cols, edgecolor="black", linewidth=0.6)
ax2.set_ylabel("Débit (Gb/s)")
ax2.set_title("Ce qui ne bouge pas :\nle débit")
ax2.set_ylim(0, max(gb) * 1.25)
for c, r, v in zip(conds, b2, gb):
    txt = f"{v:.2f}"
    if stalls[c]: txt += f"\n({stalls[c]} stall)"
    ax2.text(r.get_x()+r.get_width()/2, v+0.06, txt, ha="center", fontweight="bold")

fig.suptitle("WireGuard réception, 8 pairs, 10 GbE — médianes sur %d répétitions"
             % max(nrep.values()), fontsize=11)
fig.tight_layout(rect=[0, 0, 1, 0.94])
out1 = f"{outdir}/fig_wasted_vs_debit.png"
fig.savefig(out1, dpi=130); print("wrote", out1)

# ---- Figure 2: per-core busy% under stock (one core saturated) ----
cores, busy, soft = [], [], []
for r in csv.DictReader(open(cpu_path)):
    cores.append(r["core"].replace("cpu", "")); busy.append(float(r["busy_pct"]))
    soft.append(float(r["softirq_pct"]))
# show top ~16 by busy
idx = sorted(range(len(cores)), key=lambda i: -busy[i])[:16]
cores = [cores[i] for i in idx]; busy = [busy[i] for i in idx]; soft = [soft[i] for i in idx]
fig2, ax = plt.subplots(figsize=(9, 4))
bx = ax.bar(range(len(cores)), busy, color=["#ea4335" if v > 90 else "#9aa0a6" for v in busy],
            edgecolor="black", linewidth=0.5, label="occupation totale")
ax.bar(range(len(cores)), soft, color=["#b31412" if v > 90 else "#5f6368" for v in soft],
       width=0.5, label="dont softirq réseau")
ax.set_xticks(range(len(cores))); ax.set_xticklabels(cores)
ax.set_xlabel("cœur CPU"); ax.set_ylabel("occupation (%)"); ax.set_ylim(0, 108)
ax.set_title("Sous charge (stock) : UN seul cœur est saturé — c'est lui le goulot")
ax.legend(loc="upper right")
hot = cores[0]
ax.annotate(f"cœur {hot}\n100 % / softirq",
            xy=(0, busy[0]), xytext=(2.2, 86),
            arrowprops=dict(arrowstyle="->"), fontweight="bold")
fig2.tight_layout()
out2 = f"{outdir}/fig_cpu_coeurs.png"
fig2.savefig(out2, dpi=130); print("wrote", out2)

# ---- also dump a compact table the doc can quote ----
print("\nCONDITION   reps  wasted%  debit(Gb/s)  stalls")
for c in conds:
    print(f"{c:9}  {nrep[c]:>3}   {st.median(g[c]['wf'])*100:5.1f}   "
          f"{(st.median(g[c]['gb']) if g[c]['gb'] else 0):6.2f}      {stalls[c]}")
