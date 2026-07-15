#!/usr/bin/env python3
"""Phase D gate 1 — single-tunnel wg_steal sweep (data/cloudlab/single_*.csv).

One tunnel = one 5-tuple = one RX queue: the regime the NIC's sdfn spread cannot
help, and the only one where the receive path's per-core cost is the ceiling.
The sweep asks three things:
  1. does stealing raise throughput, and by how much (as an interval, not an anecdote)?
  2. where is the knob's knee (8 was arbitrary)?
  3. what does it cost in CPU? (the review's open question: steal-alone median 8.33 CE
     in the Phase D A/B — noise, or real cost?)

Stats note: each wg_steal value is tested against off (=0) with an EXACT permutation
test (C(10,5)=252 splits, so the smallest reachable two-sided p is ~0.008). Pooling
all steal>0 rows into one group is NOT done: the knob values have different means,
so pooling inflates the null's variance and the test becomes meaninglessly
conservative. With 5 comparisons, read p against a Bonferroni threshold of 0.01.

  python3 scripts/cloudlab/analyze_single.py [data/cloudlab/single_20260715_0516.csv]
"""
import csv, itertools, statistics as st, sys

PATH = sys.argv[1] if len(sys.argv) > 1 else "data/cloudlab/single_20260715_0516.csv"


def exact_perm_p(a, b):
    """Two-sided exact permutation test on the difference of means."""
    obs = st.mean(b) - st.mean(a)
    pool = a + b
    na, hits, tot = len(a), 0, 0
    for idx in itertools.combinations(range(len(pool)), na):
        s = set(idx)
        ai = [pool[i] for i in idx]
        bi = [pool[i] for i in range(len(pool)) if i not in s]
        tot += 1
        if abs(st.mean(bi) - st.mean(ai)) >= abs(obs) - 1e-12:
            hits += 1
    return obs, hits / tot


def main():
    rows = list(csv.DictReader(open(PATH)))
    by = {}
    for r in rows:
        by.setdefault(int(r["wg_steal"]), []).append(r)
    col = lambda rs, k, f=float: [f(r[k]) for r in rs]

    src = rows[0]["srcversion"]
    print(f"{PATH}  (srcversion {src}, {len(rows)} runs)\n")
    print(f"{'steal':>5} {'n':>2} {'Gb/s mean':>9} {'median':>7} {'min':>6} {'max':>6} "
          f"{'vs off':>7} {'busy CE':>7} {'vs off':>7} {'rtx med':>7} {'Gb/s per CE':>11}")
    off_g = col(by[0], "gbps")
    off_b = col(by[0], "total_busy_ce")
    for s in sorted(by):
        g, b = col(by[s], "gbps"), col(by[s], "total_busy_ce")
        rtx = col(by[s], "retransmits", int)
        print(f"{s:>5} {len(g):>2} {st.mean(g):>9.4f} {st.median(g):>7.4f} {min(g):>6.4f} "
              f"{max(g):>6.4f} {100*(st.mean(g)-st.mean(off_g))/st.mean(off_g):>+6.2f}% "
              f"{st.mean(b):>7.3f} {100*(st.mean(b)-st.mean(off_b))/st.mean(off_b):>+6.2f}% "
              f"{st.median(rtx):>7.0f} {st.mean(g)/st.mean(b):>11.3f}")

    for metric, key, base, unit in (("THROUGHPUT", "gbps", off_g, "Gb/s"),
                                    ("CPU", "total_busy_ce", off_b, "CE")):
        print(f"\n{metric} — exact permutation test vs off (Bonferroni threshold p<0.01):")
        for s in sorted(by):
            if s == 0:
                continue
            d, p = exact_perm_p(base, col(by[s], key))
            flag = "  <-- survives correction" if p < 0.01 else ""
            print(f"  steal={s:<2}  {d:+.4f} {unit} ({100*d/st.mean(base):+.2f}%)  p={p:.4f}{flag}")

    # Efficiency: the cleanest lens — same work, less CPU. Per-run ratio, so it is not
    # sensitive to the run-to-run throughput wobble that dominates the raw Gb/s test.
    eff = lambda rs: [float(r["gbps"]) / float(r["total_busy_ce"]) for r in rs]
    print("\nEFFICIENCY (Gb/s per busy core-equivalent) — exact permutation test vs off:")
    for s in sorted(by):
        if s == 0:
            continue
        d, p = exact_perm_p(eff(by[0]), eff(by[s]))
        print(f"  steal={s:<2}  {d:+.4f} ({100*d/st.mean(eff(by[0])):+.2f}%)  p={p:.4f}")

    dm = sum(int(r["dmesg_delta"]) for r in rows)
    print(f"\ndmesg hits across all {len(rows)} runs: {dm}")


if __name__ == "__main__":
    main()
