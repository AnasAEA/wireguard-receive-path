# Conceptual figure specification

Four vector conceptual figures support the narrative. Sources are standalone
TikZ documents under `paper/figures/conceptual/`, each compiled to a committed
PDF that `paper/03-background-motivations.tex` includes with `\includegraphics`.
They are authored as `standalone` documents (not `\input` snippets) because
`paper/main.tex` does not load TikZ and is owned by Agent 1; compiling to PDF
keeps the main build unchanged and the output vector.

## Build

From `paper/figures/conceptual/`:

```sh
tectonic c1_recv_overview.tex
tectonic c2_eoi_timeline.tex
tectonic c3_stock_vs_steal.tex
tectonic c4_investigation.tex
```

Any `standalone`-capable TeX toolchain works. The committed PDFs are the assets
the paper includes; regenerate them after editing a source.

## Shared visual language (color-blind safe, Okabe-Ito)

- amber `#E69F00` = pending / encrypted
- teal `#009E73` = decrypted / ready
- blue `#0072B2` = the stealing action / the NAPI context
- dark `#222222` = ordering barrier and default ink

Color is never the sole channel: every state also carries a text label
(`UNCRYPTED`/`CRYPTED`), and paths are distinguished by line style (solid = packet
flow, amber = work assignment, dashed = completion/state publication, thick blue
= stealing). All figures use a sans body font at `\small`/`\footnotesize` and are
designed near their target column width so text stays about 8-9 pt after scaling.

## Figures

### C1 -- Receive-path overview  (`fig:recv-overview`, single column)

- **Purpose:** teach the pipeline and the split between *work assignment*
  (device-wide ring) and *delivery ordering* (per-peer queue).
- **Entities:** NIC, RX queue, RX/NAPI poll, per-peer ordered queue (P1/P2/P3),
  device-wide decrypt ring, per-CPU workers, network stack.
- **Misreading prevented:** that the device ring preserves order. The ring is
  labeled "assigns which CPU decrypts" and the queue "preserves delivery order";
  the caption states the ring does not order packets.

### C2 -- Execution-order inversion  (`fig:eoi-timeline`, single column)

- **Purpose:** make the P1/P2 stall visible at a glance.
- **Content:** two decrypt lanes (P1 long, P2 short) plus a delivery lane; P2
  completes first; a hatched "delivery blocked" interval runs until P1 completes;
  a blue event marks the poll that runs and delivers nothing.
- **Misreading prevented:** that stock WireGuard mishandles P2. The caption says
  holding the ready P2 behind P1 is correct ordered delivery, not an error.

### C3 -- Stock versus bounded stealing  (`fig:steal-panels`, double column)

- **Purpose:** the mechanism, contrasted with stock, on one CPU.
- **Content:** left panel, the poll stops at an `UNCRYPTED` head and yields while
  pending jobs wait; right panel, the same CPU consumes up to `k=4` jobs from the
  device ring, decrypts them sequentially, rechecks the head, and resumes ordered
  delivery while workers continue in parallel.
- **Misreadings prevented (labeled on the figure):** "one CPU, sequential",
  "not four workers", "up to k=4 per pass", "order preserved". Jobs are drawn
  coming from the shared ring, and a separate "recheck head" step shows stealing
  does not directly select the head.

### C4 -- Investigation logic  (`fig:investigation`, single column)

- **Purpose:** justify the move from wake suppression to work stealing without a
  chronological diary.
- **Content:** a five-step vertical flow: premature polls observed -> wake-side
  changes remove many -> each empty poll is cheap (~0.02 CE) -> ordered-head
  blocking lasts longer (tens of us) -> bounded work stealing advances pending
  work. Side annotations: "real", "but cheap", "longer-lived".

## Not created

- **C5 (cross-regime cards):** intentionally omitted. Agent 1's Figure F
  (`fig:gate-b`) and the Cross-Regime Interpretation subsection already carry
  that comparison, and a second cross-regime graphic risks implying a threshold
  the data do not establish. If a purely conceptual two-card version is later
  wanted, it must use two discrete cards, no connecting curve, and a caption
  stating no saturation threshold is established.

## Repository note (flagged for the coordinator)

The root `.gitignore` ignores `*.pdf` with an allow-list exception only for
`paper/figures/generated/*.pdf`. The conceptual PDFs are therefore force-added
(`git add -f`) so the paper builds from a fresh checkout without editing a
non-owned file. For consistency with `generated/`, the coordinator may prefer to
add `!paper/figures/conceptual/*.pdf` to the root `.gitignore`.
