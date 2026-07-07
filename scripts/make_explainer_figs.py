#!/usr/bin/env python3
"""Generate the explainer figures embedded in docs/cloudlab/CLOUDLAB_EXPERIMENTS_LOG.md.
Conceptual diagrams (EoI timeline, pipeline, two-sided fix, fix-vs-steering) + EN
versions of the E10 budget and E11 stall figures. Style: shared palette, thin marks,
direct labels.  Usage:  /usr/bin/python3 scripts/make_explainer_figs.py
Outputs to docs/meetings/figures/.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch

INK, INK2, MUT = "#0b0b0b", "#52514e", "#8a8984"
BLUE, AQUA, RED, SURF = "#2a78d6", "#1baf7a", "#e34948", "#fcfcfb"
OUT = "docs/meetings/figures"

def box(ax, x, y, w, h, text, fc, tc="white", fs=9.5, ec="none", lw=1.2, weight="bold"):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.25",
                                fc=fc, ec=ec, lw=lw, mutation_scale=1.2))
    ax.text(x + w/2, y + h/2, text, ha="center", va="center",
            fontsize=fs, color=tc, fontweight=weight)

def arrow(ax, x1, y1, x2, y2, color=INK2, lw=1.6, style="-|>", con="arc3,rad=0"):
    ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2), arrowstyle=style,
                 connectionstyle=con, color=color, lw=lw, mutation_scale=14))

def canvas(w, h):
    fig, ax = plt.subplots(figsize=(w, h))
    fig.patch.set_facecolor(SURF); ax.set_facecolor(SURF)
    ax.set_xlim(0, 100); ax.set_ylim(0, 60); ax.axis("off")
    return fig, ax

# ============ Figure 1 — EoI timeline (the core intuition) ============
def fig_timeline():
    fig, ax = plt.subplots(figsize=(9.2, 4.6))
    fig.patch.set_facecolor(SURF); ax.set_facecolor(SURF)
    ax.set_xlim(0, 100); ax.set_ylim(-1.2, 6.6); ax.axis("off")

    lanes = {"P4 (CPU 3)": 4.6, "P3 (CPU 2)": 3.7, "P2 (CPU 1)": 2.8, "P1 (CPU 0)": 1.9}
    # decrypt spans: (start, dur). P1 queued behind other work on its CPU -> starts late
    spans = {"P2 (CPU 1)": (8, 14), "P3 (CPU 2)": (8, 10), "P4 (CPU 3)": (8, 17),
             "P1 (CPU 0)": (46, 14)}
    for lane, y in lanes.items():
        s, d = spans[lane]
        ax.text(6.5, y, lane, ha="right", va="center", fontsize=9, color=INK2)
        color = RED if lane.startswith("P1") else BLUE
        if lane.startswith("P1"):
            ax.barh(y, 46-8, left=8, height=0.52, color=MUT, alpha=0.35)
            ax.text(27, y, "queued behind other packets on CPU 0", ha="center",
                    va="center", fontsize=8, color=INK2, style="italic")
        ax.barh(y, d, left=s, height=0.52, color=color)
        ax.text(s + d/2, y, "decrypt", ha="center", va="center", fontsize=8, color="white",
                fontweight="bold")
        done_x = s + d
        ax.plot(done_x, y, marker="o", ms=5, color=INK)
    ax.text(8, 5.45, "packets arrive in order P1 P2 P3 P4 — decrypt runs in parallel",
            fontsize=9.5, color=INK)

    # delivery lane
    yD = 0.9
    ax.text(6.5, yD, "delivery", ha="right", va="center", fontsize=9, color=INK2)
    ax.barh(yD, 60-8, left=8, height=0.52, color=RED, alpha=0.25)
    ax.text(34, yD, "blocked — head P1 not ready", ha="center", va="center",
            fontsize=8.5, color=RED, fontweight="bold")
    ax.barh(yD, 14, left=60, height=0.52, color=AQUA)
    ax.text(67, yD, "P1 P2 P3 P4", ha="center", va="center", fontsize=8.5,
            color="white", fontweight="bold")

    # wasted polls lane
    yP = 0.0
    ax.text(6.5, yP, "polls", ha="right", va="center", fontsize=9, color=INK2)
    for x in (19.5, 26, 33, 39.5, 47, 53.5):
        ax.plot(x, yP, marker="x", ms=7, mew=2.2, color=RED)
    ax.plot(60.5, yP, marker="o", ms=7, color=AQUA)
    ax.text(37, -0.85, "each non-head completion rings the bell → poll finds P1 encrypted → wasted",
            fontsize=8.5, color=RED, ha="center")
    ax.text(66.5, -0.85, "useful poll", fontsize=8.5, color=AQUA, ha="left")

    ax.annotate("P2–P4 done, decrypted,\nwaiting in the ordered queue",
                xy=(25, 3.7), xytext=(58, 4.4), fontsize=8.5, color=INK2,
                arrowprops=dict(arrowstyle="->", color=INK2, lw=1))
    ax.set_title("The EoI in one picture: delivery waits for the head; polls burn in the meantime",
                 fontsize=12, color=INK, pad=10)
    fig.tight_layout()
    fig.savefig(f"{OUT}/fig_eoi_timeline_en.png", dpi=150)

# ============ Figure 2 — receive-path pipeline ============
def fig_pipeline():
    fig, ax = canvas(9.6, 4.3)
    box(ax, 2, 24, 13, 12, "NIC\nencrypted\npackets", MUT)
    for i, (lbl, y) in enumerate([("worker CPU1 — P2", 42), ("worker CPU2 — P3", 30),
                                  ("worker CPU3 — P4", 18), ("worker CPU0 — P1", 6)]):
        c = RED if "P1" in lbl else BLUE
        box(ax, 24, y, 20, 8, f"decrypt\n{lbl}", c, fs=8.5)
        arrow(ax, 15, 30, 24, y+4)
    ax.text(34, 53, "parallel decrypt → finishes OUT OF ORDER", fontsize=9.5,
            color=INK, ha="center", fontweight="bold")

    # ordered queue with cells
    qx, qy = 54, 24
    ax.text(qx+10.5, qy+15, "per-peer ORDERED queue", fontsize=9.5, color=INK,
            ha="center", fontweight="bold")
    cells = [("P1", RED, "still\nencrypted"), ("P2", AQUA, "ready"),
             ("P3", AQUA, "ready"), ("P4", AQUA, "ready")]
    for i, (p, c, note) in enumerate(cells):
        box(ax, qx + i*5.4, qy, 4.6, 9, p, c, fs=9)
        ax.text(qx + i*5.4 + 2.3, qy-3.4, note, fontsize=7, color=c if c==RED else INK2,
                ha="center")
    ax.text(qx+2.3, qy+11.5, "HEAD", fontsize=8, color=RED, ha="center", fontweight="bold")
    for y in (46, 34, 22, 10):
        arrow(ax, 44, y, 53, qy+5, con="arc3,rad=0.12")

    box(ax, 82, 23, 15, 11, "NAPI poll\ndelivers from\nthe head only", INK2)
    arrow(ax, 76, 28.5, 82, 28.5)
    # the bell
    arrow(ax, 44, 46, 84, 36, color=RED, lw=1.8, con="arc3,rad=-0.25")
    ax.text(72, 51, "EVERY completion rings the bell (napi_schedule) —\nhead encrypted ⇒ the poll runs for nothing: WASTED POLL",
            fontsize=9, color=RED, ha="center", fontweight="bold")
    ax.set_title("WireGuard receive path: where the wasted polls come from",
                 fontsize=12, color=INK, pad=8)
    fig.tight_layout()
    fig.savefig(f"{OUT}/fig_eoi_pipeline_en.png", dpi=150)

# ============ Figure 3 — the two-sided fix ============
def fig_twosided():
    fig, ax = canvas(9.6, 4.4)
    # producer side
    box(ax, 3, 38, 22, 10, "decrypt completion\n(usually NOT the head)", BLUE, fs=9)
    box(ax, 34, 38, 20, 10, "napi_schedule\n(“ring the bell”)", MUT, fs=9)
    box(ax, 66, 38, 28, 10, "poll runs, head encrypted\n→ WASTED POLL", RED, fs=9)
    arrow(ax, 25, 43, 30.5, 43); arrow(ax, 54, 43, 66, 43)
    # producer gate
    box(ax, 24.5, 25.5, 21, 7.5, "wg_headwake (producer gate):\nring ONLY if head is ready", AQUA, fs=8.2)
    arrow(ax, 35, 33, 40, 37.5, color=AQUA, lw=2)

    # consumer side (MISSED loop)
    arrow(ax, 92, 37.5, 92, 20, color=RED, lw=1.8, con="arc3,rad=-0.35")
    box(ax, 62, 12, 32, 8, "MISSED was set during the poll\n→ kernel forces an immediate RE-POLL", RED, fs=8.2)
    arrow(ax, 62, 16, 80, 37.5, color=RED, lw=1.8, con="arc3,rad=-0.3")
    box(ax, 24.5, 8, 30, 8.5, "wg_supp (consumer suppress):\nhead still encrypted at poll end\n→ clear MISSED, park instead", AQUA, fs=8.2)
    arrow(ax, 54.5, 12.5, 61.5, 14.5, color=AQUA, lw=2)

    ax.text(50, 55, "one side alone leaks — suppress the re-poll and the next completion rings a FRESH bell;\ngate the producer and in-flight MISSED re-polls still fire.  Together: 27% → 14% wasted.",
            fontsize=9.5, color=INK, ha="center")
    ax.set_title("The two-sided fix: gate the bell (producer) + suppress the re-poll (consumer)",
                 fontsize=12, color=INK, pad=8)
    fig.tight_layout()
    fig.savefig(f"{OUT}/fig_twosided_en.png", dpi=150)

# ============ Figure 4 — current fix vs steering ============
def fig_steering():
    fig, axes = plt.subplots(2, 1, figsize=(9.2, 4.8), sharex=True)
    fig.patch.set_facecolor(SURF)
    T0, T1 = 46, 60   # P1 decrypt window today
    for ax, title in zip(axes, ["today (even WITH the two-sided fix)", "steering idea (future work)"]):
        ax.set_facecolor(SURF); ax.set_xlim(0, 100); ax.set_ylim(0, 3)
        ax.axis("off")
        ax.set_title(title, fontsize=10.5, color=INK, loc="left", pad=4)
    ax = axes[0]
    ax.barh(2, 38, left=8, height=0.5, color=MUT, alpha=0.35)
    ax.text(27, 2, "P1 waits its turn (~50–100 µs measured)", ha="center", va="center", fontsize=8.5, color=INK2)
    ax.barh(2, 14, left=T0, height=0.5, color=RED)
    ax.text(T0+7, 2, "decrypt", ha="center", va="center", fontsize=8, color="white", fontweight="bold")
    ax.barh(1, 10, left=T1, height=0.5, color=AQUA)
    ax.text(T1+5, 1, "delivery", ha="center", va="center", fontsize=8, color="white", fontweight="bold")
    ax.text(8, 0.35, "the fix removed the wasted polls — but delivery still starts at the same instant",
            fontsize=8.5, color=INK2)
    ax = axes[1]
    S0 = 12
    ax.barh(2, 14, left=S0, height=0.5, color=BLUE)
    ax.text(S0+7, 2, "decrypt", ha="center", va="center", fontsize=8, color="white", fontweight="bold")
    ax.text(S0+16, 2, "← the next FREE cpu takes the head first", fontsize=8.5, color=BLUE, va="center")
    ax.barh(1, 10, left=S0+14, height=0.5, color=AQUA)
    ax.text(S0+19, 1, "delivery", ha="center", va="center", fontsize=8, color="white", fontweight="bold")
    ax.annotate("", xy=(S0+14, 0.5), xytext=(T1, 0.5),
                arrowprops=dict(arrowstyle="<->", color=AQUA, lw=1.6))
    ax.text((S0+14+T1)/2, 0.18, "recoverable: ~30–90 µs typical, 200–800 µs tail (E11 bound, pending classifier)",
            ha="center", fontsize=8.5, color=AQUA, fontweight="bold")
    fig.suptitle("Why the wake-side fix can't move latency — and what could", fontsize=12,
                 color=INK, y=0.99)
    fig.tight_layout(rect=(0, 0, 1, 0.96))
    fig.savefig(f"{OUT}/fig_fix_vs_steering_en.png", dpi=150)

# ============ EN versions of the analytical figures ============
def fig_budget_en():
    labels = ["total busy CPU\n(median under load)", "run-to-run noise\n(±2 CE)",
              "ALL wasted polls, baseline\n(measured, E10)", "reclaimed by the fix\n(measured, E10)"]
    vals = [7.3, 2.0, 0.022, 0.017]
    cols = [MUT, MUT, RED, BLUE]
    txt  = ["7.3 CE", "2 CE", "0.022 CE", "0.017 CE"]
    fig, ax = plt.subplots(figsize=(7.4, 3.9))
    fig.patch.set_facecolor(SURF); ax.set_facecolor(SURF)
    y = range(len(vals))[::-1]
    ax.barh(y, vals, height=0.55, color=cols, log=True)
    for yi, v, t in zip(y, vals, txt):
        ax.text(v*1.25, yi, t, va="center", fontsize=11, color=INK, fontweight="bold")
    ax.set_yticks(list(y)); ax.set_yticklabels(labels, fontsize=9.5, color=INK2)
    ax.set_xlim(0.008, 40)
    ax.set_xlabel("cores-equivalent (CE) — log scale", fontsize=9.5, color=INK2)
    ax.set_title("E10 — the measured wasted-poll budget: a sliver", fontsize=12, color=INK, pad=12)
    ax.annotate("100× below the noise", xy=(0.022, 1), xytext=(0.35, 0.55), fontsize=9.5,
                color=RED, arrowprops=dict(arrowstyle="->", color=RED, lw=1.2))
    ax.spines[["top", "right", "left"]].set_visible(False)
    ax.tick_params(axis="x", labelsize=8.5, colors=INK2)
    ax.grid(axis="x", alpha=0.25, lw=0.6); ax.set_axisbelow(True)
    fig.tight_layout(); fig.savefig(f"{OUT}/fig_e10_budget_en.png", dpi=140)

def fig_stall_en():
    buckets = ["2–4","4–8","8–16","16–32","32–64","64–128","128–256","256–512","0.5–1k","1k–2k","2k–4k","4k–8k","8k–16k"]
    counts  = [2,1575,6627,20741,88828,63038,16845,20586,7611,2632,5717,2749,6691]
    cols2 = [BLUE]*10 + [MUT]*3
    fig, ax = plt.subplots(figsize=(7.6, 4.5))
    fig.patch.set_facecolor(SURF); ax.set_facecolor(SURF)
    x = range(len(buckets))
    ax.bar(x, counts, width=0.72, color=cols2, edgecolor=SURF, linewidth=2)
    ax.set_xticks(list(x)); ax.set_xticklabels(buckets, fontsize=8.5, color=INK2, rotation=45, ha="right")
    ax.set_xlabel("blocked duration (µs) — power-of-2 buckets", fontsize=9.5, color=INK2)
    ax.set_ylabel("episodes (30 s, delay 0, baseline)", fontsize=9.5, color=INK2)
    ax.set_title("E11 — how long delivery stays blocked (243,642 episodes)", fontsize=12, color=INK, pad=12)
    ax.set_ylim(0, 105000)
    ax.axvline(1.35, color=RED, lw=1.4, ls="--")
    ax.text(1.6, 96500, "T_decrypt ≈ 5 µs: if decrypt alone blocked delivery, everything would sit left of this line",
            fontsize=9, color=RED, va="top")
    ax.annotate("the bulk: 32–128 µs ≈ 10–20× T_decrypt\n→ the head WAITS ITS TURN to be decrypted,\n    it is not slow to decrypt",
                xy=(5.2, 63038), xytext=(6.4, 72000), fontsize=9.5, color=INK,
                arrowprops=dict(arrowstyle="->", color=INK2, lw=1.1))
    ax.text(11.0, 26000, "ms population:\nidle gaps between bursts\n(excluded from analysis)",
            fontsize=9, color=MUT, ha="center")
    ax.spines[["top", "right"]].set_visible(False)
    ax.tick_params(axis="y", labelsize=8.5, colors=INK2)
    ax.grid(axis="y", alpha=0.25, lw=0.6); ax.set_axisbelow(True)
    fig.tight_layout(); fig.savefig(f"{OUT}/fig_e11_stall_en.png", dpi=140)



# ============ FR variants of the four conceptual figures ============
def fig_timeline_fr():
    fig, ax = plt.subplots(figsize=(9.2, 4.6))
    fig.patch.set_facecolor(SURF); ax.set_facecolor(SURF)
    ax.set_xlim(0, 100); ax.set_ylim(-1.2, 6.6); ax.axis("off")
    lanes = {"P4 (CPU 3)": 4.6, "P3 (CPU 2)": 3.7, "P2 (CPU 1)": 2.8, "P1 (CPU 0)": 1.9}
    spans = {"P2 (CPU 1)": (8, 14), "P3 (CPU 2)": (8, 10), "P4 (CPU 3)": (8, 17),
             "P1 (CPU 0)": (46, 14)}
    for lane, y in lanes.items():
        s, d = spans[lane]
        ax.text(6.5, y, lane, ha="right", va="center", fontsize=9, color=INK2)
        color = RED if lane.startswith("P1") else BLUE
        if lane.startswith("P1"):
            ax.barh(y, 46-8, left=8, height=0.52, color=MUT, alpha=0.35)
            ax.text(27, y, "en file derrière d'autres paquets sur le CPU 0", ha="center",
                    va="center", fontsize=8, color=INK2, style="italic")
        ax.barh(y, d, left=s, height=0.52, color=color)
        ax.text(s + d/2, y, "déchiffre", ha="center", va="center", fontsize=8,
                color="white", fontweight="bold")
        ax.plot(s + d, y, marker="o", ms=5, color=INK)
    ax.text(8, 5.45, "les paquets arrivent dans l'ordre P1 P2 P3 P4 — le déchiffrement est parallèle",
            fontsize=9.5, color=INK)
    yD = 0.9
    ax.text(6.5, yD, "livraison", ha="right", va="center", fontsize=9, color=INK2)
    ax.barh(yD, 60-8, left=8, height=0.52, color=RED, alpha=0.25)
    ax.text(34, yD, "bloquée — la tête P1 n'est pas prête", ha="center", va="center",
            fontsize=8.5, color=RED, fontweight="bold")
    ax.barh(yD, 14, left=60, height=0.52, color=AQUA)
    ax.text(67, yD, "P1 P2 P3 P4", ha="center", va="center", fontsize=8.5,
            color="white", fontweight="bold")
    yP = 0.0
    ax.text(6.5, yP, "polls", ha="right", va="center", fontsize=9, color=INK2)
    for x in (19.5, 26, 33, 39.5, 47, 53.5):
        ax.plot(x, yP, marker="x", ms=7, mew=2.2, color=RED)
    ax.plot(60.5, yP, marker="o", ms=7, color=AQUA)
    ax.text(33, -0.85, "chaque fin non-tête sonne la cloche → le poll trouve P1 chiffré → gaspillé",
            fontsize=8.5, color=RED, ha="center")
    ax.text(63, -0.85, "poll utile", fontsize=8.5, color=AQUA, ha="left")
    ax.annotate("P2–P4 finis, déchiffrés,\nen attente dans la file ordonnée",
                xy=(25, 3.7), xytext=(58, 4.4), fontsize=8.5, color=INK2,
                arrowprops=dict(arrowstyle="->", color=INK2, lw=1))
    ax.set_title("L'EoI en une image : la livraison attend la tête ; les polls brûlent pendant ce temps",
                 fontsize=12, color=INK, pad=10)
    fig.tight_layout(); fig.savefig(f"{OUT}/fig_eoi_timeline_fr.png", dpi=150)

def fig_pipeline_fr():
    fig, ax = canvas(9.6, 4.3)
    box(ax, 2, 24, 13, 12, "NIC\npaquets\nchiffrés", MUT)
    for lbl, y in [("worker CPU1 — P2", 42), ("worker CPU2 — P3", 30),
                   ("worker CPU3 — P4", 18), ("worker CPU0 — P1", 6)]:
        c = RED if "P1" in lbl else BLUE
        box(ax, 24, y, 20, 8, f"déchiffrement\n{lbl}", c, fs=8.5)
        arrow(ax, 15, 30, 24, y+4)
    ax.text(34, 53, "déchiffrement parallèle → finit DANS LE DÉSORDRE", fontsize=9.5,
            color=INK, ha="center", fontweight="bold")
    qx, qy = 54, 24
    ax.text(qx+10.5, qy+15, "file ORDONNÉE par pair", fontsize=9.5, color=INK,
            ha="center", fontweight="bold")
    cells = [("P1", RED, "encore\nchiffré"), ("P2", AQUA, "prêt"),
             ("P3", AQUA, "prêt"), ("P4", AQUA, "prêt")]
    for i, (p, c, note) in enumerate(cells):
        box(ax, qx + i*5.4, qy, 4.6, 9, p, c, fs=9)
        ax.text(qx + i*5.4 + 2.3, qy-3.4, note, fontsize=7,
                color=c if c==RED else INK2, ha="center")
    ax.text(qx+2.3, qy+11.5, "TÊTE", fontsize=8, color=RED, ha="center", fontweight="bold")
    for y in (46, 34, 22, 10):
        arrow(ax, 44, y, 53, qy+5, con="arc3,rad=0.12")
    box(ax, 82, 23, 15, 11, "poll NAPI\nlivre depuis la\ntête seulement", INK2)
    arrow(ax, 76, 28.5, 82, 28.5)
    arrow(ax, 44, 46, 84, 36, color=RED, lw=1.8, con="arc3,rad=-0.25")
    ax.text(72, 51, "CHAQUE fin de déchiffrement sonne la cloche (napi_schedule) —\ntête chiffrée ⇒ le poll tourne pour rien : POLL GASPILLÉ",
            fontsize=9, color=RED, ha="center", fontweight="bold")
    ax.set_title("Le chemin de réception WireGuard : d'où viennent les polls gaspillés",
                 fontsize=12, color=INK, pad=8)
    fig.tight_layout(); fig.savefig(f"{OUT}/fig_eoi_pipeline_fr.png", dpi=150)

def fig_twosided_fr():
    fig, ax = canvas(9.6, 4.4)
    box(ax, 3, 38, 22, 10, "fin de déchiffrement\n(généralement PAS la tête)", BLUE, fs=9)
    box(ax, 34, 38, 20, 10, "napi_schedule\n(« sonner la cloche »)", MUT, fs=9)
    box(ax, 66, 38, 28, 10, "le poll tourne, tête chiffrée\n→ POLL GASPILLÉ", RED, fs=9)
    arrow(ax, 25, 43, 30.5, 43); arrow(ax, 54, 43, 66, 43)
    box(ax, 20, 25, 27, 8, "wg_headwake (barrière producteur) :\nsonner SEULEMENT si la tête est prête", AQUA, fs=8.2)
    arrow(ax, 40, 33.5, 42, 37.5, color=AQUA, lw=2)
    arrow(ax, 92, 37.5, 92, 20, color=RED, lw=1.8, con="arc3,rad=-0.35")
    box(ax, 62, 12, 32, 8, "MISSED posé pendant le poll\n→ le noyau force un RE-POLL immédiat", RED, fs=8.2)
    arrow(ax, 62, 16, 80, 37.5, color=RED, lw=1.8, con="arc3,rad=-0.3")
    box(ax, 24.5, 8, 30, 8.5, "wg_supp (suppression consommateur) :\ntête encore chiffrée en fin de poll\n→ effacer MISSED, se garer", AQUA, fs=8.2)
    arrow(ax, 54.5, 12.5, 61.5, 14.5, color=AQUA, lw=2)
    ax.text(50, 55, "un seul côté fuit — supprime le re-poll et la fin suivante sonne une cloche NEUVE ;\nbarre le producteur et les re-polls MISSED en vol partent quand même.  Ensemble : 27 % → 14 % gaspillés.",
            fontsize=9.5, color=INK, ha="center")
    ax.set_title("Le fix deux-côtés : barrer la cloche (producteur) + supprimer le re-poll (consommateur)",
                 fontsize=12, color=INK, pad=8)
    fig.tight_layout(); fig.savefig(f"{OUT}/fig_twosided_fr.png", dpi=150)

def fig_steering_fr():
    fig, axes = plt.subplots(2, 1, figsize=(9.2, 4.8), sharex=True)
    fig.patch.set_facecolor(SURF)
    T0, T1 = 46, 60
    for ax, title in zip(axes, ["aujourd'hui (même AVEC le fix deux-côtés)",
                                "l'idée steering (travail futur)"]):
        ax.set_facecolor(SURF); ax.set_xlim(0, 100); ax.set_ylim(0, 3); ax.axis("off")
        ax.set_title(title, fontsize=10.5, color=INK, loc="left", pad=4)
    ax = axes[0]
    ax.barh(2, 38, left=8, height=0.5, color=MUT, alpha=0.35)
    ax.text(27, 2, "P1 attend son tour (~50–100 µs mesurés)", ha="center", va="center",
            fontsize=8.5, color=INK2)
    ax.barh(2, 14, left=T0, height=0.5, color=RED)
    ax.text(T0+7, 2, "déchiffre", ha="center", va="center", fontsize=8, color="white", fontweight="bold")
    ax.barh(1, 10, left=T1, height=0.5, color=AQUA)
    ax.text(T1+5, 1, "livraison", ha="center", va="center", fontsize=8, color="white", fontweight="bold")
    ax.text(8, 0.35, "le fix a supprimé les polls gaspillés — mais la livraison démarre au même instant",
            fontsize=8.5, color=INK2)
    ax = axes[1]
    S0 = 12
    ax.barh(2, 14, left=S0, height=0.5, color=BLUE)
    ax.text(S0+7, 2, "déchiffre", ha="center", va="center", fontsize=8, color="white", fontweight="bold")
    ax.text(S0+16, 2, "← le prochain CPU LIBRE prend la tête en premier", fontsize=8.5,
            color=BLUE, va="center")
    ax.barh(1, 10, left=S0+14, height=0.5, color=AQUA)
    ax.text(S0+19, 1, "livraison", ha="center", va="center", fontsize=8, color="white", fontweight="bold")
    ax.annotate("", xy=(S0+14, 0.5), xytext=(T1, 0.5),
                arrowprops=dict(arrowstyle="<->", color=AQUA, lw=1.6))
    ax.text((S0+14+T1)/2, 0.18, "récupérable : ~30–90 µs typiques, queue 200–800 µs (borne E11, en attente du classifieur)",
            ha="center", fontsize=8.5, color=AQUA, fontweight="bold")
    fig.suptitle("Pourquoi le fix côté réveil ne peut pas bouger la latence — et ce qui pourrait",
                 fontsize=12, color=INK, y=0.99)
    fig.tight_layout(rect=(0, 0, 1, 0.96))
    fig.savefig(f"{OUT}/fig_fix_vs_steering_fr.png", dpi=150)

if __name__ == "__main__":
    fig_timeline(); fig_pipeline(); fig_twosided(); fig_steering()
    fig_budget_en(); fig_stall_en()
    fig_timeline_fr(); fig_pipeline_fr(); fig_twosided_fr(); fig_steering_fr()
    print("wrote 10 figures to", OUT)
