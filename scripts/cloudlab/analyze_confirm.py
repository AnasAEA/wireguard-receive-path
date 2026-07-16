#!/usr/bin/env python3
"""Phase D confirmation — paired within-block analysis.

Handles BOTH gate artifacts (mode autodetected from the CSV header):
  confirm_*.csv    gate A: uncapped single-tunnel replication of Finding 8
  fixedload_*.csv  gate B: matched-load CPU + same-tunnel tail latency

Decision rules (declared BEFORE the runs — do not move the goalposts after):
  Gate A primary   steal4-off on gbps: Finding 8's +4% REPLICATES if the mean
                   within-block delta is >0 with sign-flip p<0.05;
                   steal4-off on total_busy_ce: the CPU claim replicates if <0
                   with p<0.05. Both hold -> the headline is frozen as-is.
  Gate B primary   steal4-off on total_busy_ce at matched load ("same bytes,
                   less CPU"). VALIDITY GATE first: per-condition mean load
                   must agree within 1.5%, otherwise the CPU comparison is void.
  Composition      bsteal4-steal4: >0 and p<0.05 -> complementary (claim a
                   cumulative effect); |delta| small / p large -> redundant
                   (wake fixes clean the mechanism, add no user-visible perf —
                   an honest, expected outcome); <0 and p<0.05 -> antagonistic
                   (report as an interaction, not as a broken fix).
  Wake-only null   both-off: expected ~0 on gbps/CPU (Phase A/E10 said the
                   wasted polls are cheap); a significant result here would be
                   NEWS and needs a rerun before being believed.
  Latency (gate B) p99/p99.9 same-tunnel deltas are EXPLORATORY. A null stays
                   in the report as a null; the CPU/throughput claim stands on
                   its own either way.

Stats: exact sign-flip test on within-block deltas. Under H0 each block's
delta is symmetric around 0, so all 2^B sign assignments are equally likely;
two-sided p = fraction of assignments with |mean| >= |observed|. With B=12
the smallest reachable p is 2/4096 ~= 0.0005 — real resolution, unlike the
n=5 sweep's floor of 0.008. No pooling across conditions (lesson of the
sweep's first analysis). The classifier columns (unc_*) are only comparable
between conditions that leave wg_supp off (off, steal4): suppression biases
episode observation under both/bsteal4.

  python3 scripts/cloudlab/analyze_confirm.py data/cloudlab/confirm_<TS>.csv
  python3 scripts/cloudlab/analyze_confirm.py data/cloudlab/fixedload_<TS>.csv
"""
import csv, statistics as st, sys

CONDS = ["off", "both", "steal4", "bsteal4"]
COMPS = [("steal4", "off"), ("bsteal4", "steal4"), ("bsteal4", "off"), ("both", "off")]


def val(row, key):
    try:
        return float(row[key])
    except (KeyError, ValueError, TypeError):
        return None


def signflip_p(deltas):
    """Exact two-sided sign-flip test on the mean of paired deltas."""
    n = len(deltas)
    if n > 20:
        raise SystemExit(f"{n} blocks: exact 2^n enumeration too large, subsample or extend")
    obs = st.mean(deltas)
    hits = 0
    for m in range(1 << n):
        s = sum(d if (m >> i) & 1 else -d for i, d in enumerate(deltas))
        if abs(s / n) >= abs(obs) - 1e-12:
            hits += 1
    return obs, hits / (1 << n)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "data/cloudlab/confirm.csv"
    rows = list(csv.DictReader(open(path)))
    mode = "fixedload" if "p999_us" in rows[0] else "confirm"

    blocks = {}
    for r in rows:
        blocks.setdefault(r["block"], {})[r["cond"]] = r
    complete = {b: c for b, c in blocks.items() if all(k in c for k in CONDS)}
    dropped = sorted(set(blocks) - set(complete))
    if dropped:
        print(f"WARNING: dropping incomplete block(s) {dropped}", file=sys.stderr)

    src = rows[0]["srcversion"]
    print(f"{path}  (mode {mode}, srcversion {src}, {len(complete)} complete blocks)\n")

    if mode == "confirm":
        metrics = [("gbps", lambda r: val(r, "gbps")),
                   ("total_busy_ce", lambda r: val(r, "total_busy_ce")),
                   ("eff Gb/s per CE", lambda r: (val(r, "gbps") or 0) / v
                    if (v := val(r, "total_busy_ce")) else None)]
    else:
        metrics = [("total_busy_ce", lambda r: val(r, "total_busy_ce")),
                   ("softirq_ce", lambda r: val(r, "softirq_ce")),
                   ("p50_us", lambda r: val(r, "p50_us")),
                   ("p99_us", lambda r: val(r, "p99_us")),
                   ("p999_us", lambda r: val(r, "p999_us"))]

    # per-condition summary (means over complete blocks)
    hdr = [m for m, _ in metrics]
    print(f"{'cond':>8} " + " ".join(f"{h:>16}" for h in hdr))
    for c in CONDS:
        cells = []
        for _, f in metrics:
            vs = [f(complete[b][c]) for b in complete if f(complete[b][c]) is not None]
            cells.append(f"{st.mean(vs):>16.4f}" if vs else f"{'NA':>16}")
        print(f"{c:>8} " + " ".join(cells))

    # gate B validity: the CPU comparison is only meaningful at matched load
    if mode == "fixedload":
        means = {}
        for c in CONDS:
            vs = [val(complete[b][c], "load_gbps") for b in complete]
            vs = [v for v in vs if v is not None]
            means[c] = st.mean(vs) if vs else float("nan")
        lo, hi = min(means.values()), max(means.values())
        spread = 100 * (hi - lo) / lo if lo else float("inf")
        verdict = "OK" if spread <= 1.5 else "VOID — conditions did not hold the same load"
        print(f"\nload sanity: per-cond means " +
              " ".join(f"{c}={means[c]:.3f}" for c in CONDS) +
              f"  spread {spread:.2f}%  -> {verdict}")

    for name, f in metrics:
        print(f"\n{name} — within-block deltas, exact sign-flip test:")
        for a, b in COMPS:
            deltas = []
            for blk in sorted(complete, key=lambda x: int(x)):
                va, vb = f(complete[blk][a]), f(complete[blk][b])
                if va is not None and vb is not None:
                    deltas.append(va - vb)
            if len(deltas) < 4:
                print(f"  {a}-{b}: only {len(deltas)} usable blocks, skipped")
                continue
            base = st.mean([f(complete[blk][b]) for blk in complete
                            if f(complete[blk][b]) is not None])
            obs, p = signflip_p(deltas)
            pos = sum(1 for d in deltas if d > 0)
            print(f"  {a:>7}-{b:<7} {obs:+9.4f} ({100*obs/base:+.2f}%)  "
                  f"{pos}/{len(deltas)} blocks positive  p={p:.4f}")

    # mechanism sanity when the diag counters were on (off vs steal4 only:
    # the classifier is biased under wg_supp)
    if val(rows[0], "unc_total_ns") is not None:
        print("\nclassifier (unc_* valid only for off/steal4 — wg_supp biases it):")
        for c in ("off", "steal4"):
            secs = [val(complete[b][c], "unc_total_ns") / 1e9 for b in complete
                    if val(complete[b][c], "unc_total_ns") is not None]
            pulls = [val(complete[b][c], "steal_pulled") for b in complete
                     if val(complete[b][c], "steal_pulled") is not None]
            print(f"  {c:>7}: blocked {st.mean(secs):.2f} s/window"
                  f"   steal_pulled mean {st.mean(pulls):,.0f}" if secs else f"  {c}: NA")

    dm = sum(int(r["dmesg_delta"]) for r in rows if r["dmesg_delta"].isdigit())
    print(f"\ndmesg hits across all {len(rows)} runs: {dm}")


if __name__ == "__main__":
    main()
